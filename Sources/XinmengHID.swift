import Foundation
import IOKit
import IOKit.hid

/// 「输入监控」（Input Monitoring）权限处理。
///
/// macOS 上 LaunchServices 启动的 App 打开 HID 设备需要该权限，
/// 未授权时 IOHIDManagerOpen 返回 kIOReturnNotPermitted（0xE00002E2），
/// 且系统不会主动弹窗，必须调用 IOHIDRequestAccess 触发。
/// （终端里运行不受限，因为终端自身已持有该权限——这就是命令行能读、
/// GUI 读不到的原因。）
@_silgen_name("IOHIDCheckAccess")
private func _IOHIDCheckAccess(_ requestType: UInt32) -> UInt32
@_silgen_name("IOHIDRequestAccess")
private func _IOHIDRequestAccess(_ requestType: UInt32) -> Bool

private enum HIDInputPermission {
    // kIOHIDRequestTypeListenEvent
    private static let listenEvent: UInt32 = 1

    /// 返回空串表示已授权；否则返回给用户的指引文案
    static func requestIfNeeded() -> String {
        let status = _IOHIDCheckAccess(listenEvent)   // 0=granted 1=denied 2=unknown
        guard status != 0 else { return "" }
        _ = _IOHIDRequestAccess(listenEvent)          // 触发系统授权弹窗
        let after = _IOHIDCheckAccess(listenEvent)
        switch after {
        case 0: return ""
        case 1: return "「输入监控」权限被拒绝。请到 系统设置 › 隐私与安全性 › 输入监控 启用 PowerMeter，然后重启 App"
        default: return "已请求「输入监控」权限，请在弹窗中允许（或到 系统设置 › 隐私与安全性 › 输入监控 启用），然后重启 App"
        }
    }
}

/// 一条 vendor input report 的解析结果。
///
/// 抽成纯函数是为了能脱离硬件回归测试：抓到的真实样本可直接喂进来验证。
enum XinmengReport {
    case battery(level: Int, charging: Bool)
    /// 接收器在线、但键盘未连接（关机 / 休眠 / 不在 2.4G 模式）
    case offline
    /// 心跳、LED 状态等与电量无关的报文
    case ignored

    /// 实测样本（`13` 开头，第 7 字节电量、第 8 字节充电状态）：
    /// - `13 0a 01 00 04 05 63 01` → 99%，放电中
    /// - `13 0a 01 00 04 05 64 11` → 100%，充电中
    /// - `13 0a 01 00 04 02 01 00` → 键盘未连接时的占位报文，电量字节的 1% 是假的
    ///
    /// 对比可 online/offline 样本可见第 6 字节随连接状态变化（0x05 / 0x02），
    /// 判定为连接状态字节。该推断未经厂商确认，故只在 0x02 这一个取值上生效：
    /// 万一它其实别有含义，最坏也只是少显示一次读数，不会编造电量。
    private static let linkByteIndex = 5
    private static let linkOffline: UInt8 = 0x02
    private static let capacityIndex = 6
    private static let statusIndex = 7
    /// 充电状态字节的有效取值：0x01 放电、0x10 / 0x11 充电
    private static let validStatus: Set<UInt8> = [0x01, 0x10, 0x11]

    static func parse(_ data: [UInt8], length: Int) -> XinmengReport {
        guard length >= 8, data[0] == 0x13 else { return .ignored }
        // 21 字节长报文带校验和（末字节 = 前面所有字节之和的低 8 位）；
        // macOS 上的 8 字节短报文不带校验和，跳过验证
        if length > 8 {
            let sum = data.prefix(length - 1).reduce(0 as UInt8) { $0 &+ $1 }
            guard sum == data[length - 1] else { return .ignored }
        }
        // 未连接占位报文：连接字节 0x02，此时电量字节是无效值，绝不能当读数
        if data[linkByteIndex] == linkOffline { return .offline }
        // 状态字节为 0 表示这条报文没携带有效电量信息（键盘休眠时也会这样发）
        guard validStatus.contains(data[statusIndex]) else { return .ignored }
        let capacity = Int(data[capacityIndex])
        guard (1...100).contains(capacity) else { return .ignored }
        return .battery(level: capacity, charging: data[statusIndex] == 0x10 || data[statusIndex] == 0x11)
    }
}

/// 新盟（Xinmeng）2.4G 接收器的厂商私有电量协议。
///
/// 接收器 VID 0x3554（A99 / M71 等型号共用接收器固件），vendor 接口
/// usage page 0xFF02。电量通过 Input Report `0x13` 主动上报：
///
/// - `report[6]` = 电量百分比（0–100）
/// - `report[7]` = 充电状态，0x10 / 0x11 表示充电中
/// - `report[5]` = 连接状态，0x02 表示键盘未连接（此时电量字节无效）
///
/// 协议逆向自 Linux 内核 `drivers/hid/hid-xinmeng.c`（2025 年合入），
/// hidrec 采样确认：`13 0a 01 00 04 05 63 01` → 99% 放电，
/// `13 0a 01 00 04 05 64 11` → 100% 充电。内核驱动没有处理断开状态
/// （`online` 标志只置真），键盘关机时的占位报文会被当成真实电量——
/// 这就是「键盘已关机却显示 1%」的来源，本实现对此做了过滤。
///
/// 注意：`GetFeature(0x13)` 返回全零，只能被动监听 input report，
/// 因此需要常驻会话（与罗技 HID++ 同样的后台线程模式）。
/// 会话的读数状态机（与 HID 无关，可脱离硬件测试）。
struct XinmengState {
    var level: Int?
    var charging = false
    var lastReport: Date?
    /// 键盘是否连接在接收器上（nil = 还没收到过报文，状态未知）
    var keyboardOnline: Bool?
    var startedAt = Date()

    /// 曾经读到过读数后，超过这个时长没有任何报文就认为键盘已关机
    static let offlineAfterSilence: TimeInterval = 300
    /// 从没收到过报文时，只给这么长的等待窗口（在线时 15–30 秒就会来一条）
    static let handshakeGrace: TimeInterval = 60
    /// 报文间隔超过这个时长，读数标为「陈旧」（保留数值但界面置灰）
    static let staleAfter: TimeInterval = 120

    mutating func apply(report data: [UInt8], length: Int) {
        switch XinmengReport.parse(data, length: length) {
        case .battery(let capacity, let isCharging):
            keyboardOnline = true
            level = capacity
            charging = isCharging
            lastReport = Date()
        case .offline:
            // 收到报文说明接收器还插着，但键盘没连上：清掉读数，避免显示占位报文里的假电量
            keyboardOnline = false
            lastReport = Date()
        case .ignored:
            break
        }
    }

    struct Reading {
        var level: Int?
        var charging: Bool
        /// 明确收到「未连接」占位报文
        var offline: Bool
        /// 长时间没有任何报文
        var silent: Bool
        var stale: Bool
        var detail: String
        /// 键盘没连上：此时不该出现在设备列表里（接收器插着不代表键盘在线）
        var disconnected: Bool { offline || silent }
    }

    func reading(now: Date = Date()) -> Reading {
        let lastActivity = lastReport ?? startedAt
        let grace = lastReport == nil ? XinmengState.handshakeGrace : XinmengState.offlineAfterSilence
        let silent = now.timeIntervalSince(lastActivity) > grace
        let offline = keyboardOnline == false
        let disconnected = offline || silent
        let detail: String
        if offline {
            detail = "接收器在线，键盘未连接（已关机或不在 2.4G 模式）"
        } else if level == nil {
            detail = "已找到接收器，等待电量报文"
        } else {
            detail = "厂商私有协议 0x13"
        }
        let stale = !disconnected && level != nil &&
            (lastReport == nil || now.timeIntervalSince(lastReport!) > XinmengState.staleAfter)
        return Reading(level: disconnected ? nil : level,
                       charging: disconnected ? false : charging,
                       offline: offline,
                       silent: silent,
                       stale: stale,
                       detail: detail)
    }
}

final class XinmengSession {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 64)

    private var state = XinmengState()
    private var receiverPID: Int = 0
    /// 会话创建失败的原因（nil 表示正常），用于诊断「为什么新盟设备没出现」
    private(set) var failureReason: String?

    init() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x3554,
            kIOHIDPrimaryUsagePageKey: 0xFF02
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let openRC = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        let matched = openRC == kIOReturnSuccess ? IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> : nil
        guard let dev = matched?.first else {
            if UInt32(bitPattern: openRC) == 0xE00002E2 {
                // kIOReturnNotPermitted：缺「输入监控」权限，触发系统授权弹窗
                let guidance = HIDInputPermission.requestIfNeeded()
                failureReason = guidance.isEmpty ? "权限已就绪，等待下次刷新重试" : guidance
            } else {
                failureReason = "IOHIDManagerOpen rc=\(openRC)，未匹配到 0x3554 vendor 接口（count=\(matched?.count ?? -1)）"
            }
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            return
        }

        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            failureReason = "IOHIDDeviceOpen 失败（接收器被其它进程占用？）"
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
            manager = nil
            return
        }
        device = dev
        manager = mgr
        receiverPID = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0

        IOHIDDeviceRegisterInputReportCallback(dev, &buffer, 64, { context, _, _, _, _, report, length in
            guard let context = context, length > 7 else { return }
            let session = Unmanaged<XinmengSession>.fromOpaque(context).takeUnretainedValue()
            session.handle(report: (0..<length).map { report[$0] }, length: length)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if let dev = device {
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func handle(report data: [UInt8], length: Int) {
        state.apply(report: data, length: length)
    }

    /// 接收器插着、但键盘没连上（已关机 / 休眠 / 不在 2.4G 模式）
    var isKeyboardDisconnected: Bool {
        failureReason == nil && state.reading().disconnected
    }

    /// 接收器是否在线（即会话建立成功）
    var isReceiverPresent: Bool { failureReason == nil }

    func snapshot() -> [DeviceBattery] {
        // 会话创建失败时不产出设备（避免展示一个必然无读数的假行）
        guard failureReason == nil else { return [] }
        let name = "新盟键盘（2.4G）"
        let now = Date()
        let reading = state.reading(now: now)
        // 键盘没连上（关机 / 休眠 / 不在 2.4G 模式）时直接不产出这一行：
        // 接收器插在电脑上并不等于键盘在线，列出来只会展示过时或虚假的电量
        guard !reading.disconnected else { return [] }

        var extra = ["接收器": String(format: "VID 0x3554 PID 0x%04X", receiverPID)]
        if let date = state.lastReport {
            let seconds = Int(now.timeIntervalSince(date))
            extra["报文"] = seconds < 60 ? "\(max(seconds, 1)) 秒前" : "\(seconds / 60) 分钟前"
        }

        return [DeviceBattery(
            id: "xinmeng-2.4g",
            name: name,
            kind: .keyboard,
            transport: .usb,
            level: reading.level,
            charging: reading.charging,
            connected: true,
            source: .vendorHID,
            detail: reading.detail,
            lastUpdate: state.lastReport ?? Date(),
            stale: reading.stale,
            extra: extra
        )]
    }
}

/// 在独立线程上持有新盟会话（回调必须调度到创建会话的 runloop）
final class XinmengProvider {
    private let lock = NSLock()
    private var queue: [() -> Void] = []
    private var thread: Thread?
    private var session: XinmengSession?
    /// 最近一次会话状态，供诊断
    private(set) var lastStatus: String?

    private func ensureThread() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.runloop() }
        t.name = "PowerMeter.Xinmeng"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    private func enqueue(_ work: @escaping () -> Void) {
        lock.lock()
        queue.append(work)
        lock.unlock()
    }

    private func runloop() {
        while true {
            lock.lock()
            let pending = queue
            queue.removeAll()
            lock.unlock()
            for work in pending { work() }
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
    }

    func snapshot(completion: @escaping ([DeviceBattery], String?) -> Void) {
        ensureThread()
        enqueue { [weak self] in
            guard let self = self else { return }
            // 失败过的会话在下次刷新时重建（典型场景：用户刚在系统设置里补授「输入监控」权限）
            if let session = self.session, session.failureReason != nil {
                self.session = nil
            }
            if self.session == nil { self.session = XinmengSession() }
            let devices = self.session?.failureReason == nil ? (self.session?.snapshot() ?? []) : []
            var status = self.session?.failureReason
            // 键盘关机时设备行会被隐藏，这里说明原因，避免「接收器插着却看不到键盘」让人困惑
            if status == nil, self.session?.isKeyboardDisconnected == true {
                status = "接收器在线，但键盘未连接（已关机或休眠），已从列表隐藏"
            }
            self.lastStatus = status
            DispatchQueue.main.async { completion(devices, status) }
        }
    }
}
