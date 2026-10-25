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

/// 新盟（Xinmeng）2.4G 接收器的厂商私有电量协议。
///
/// 接收器 VID 0x3554（A99 / M71 等型号共用接收器固件），vendor 接口
/// usage page 0xFF02。电量通过 Input Report `0x13` 主动上报：
///
/// - `report[6]` = 电量百分比（0–100）
/// - `report[7]` = 充电状态，0x10 / 0x11 表示充电中
///
/// 协议逆向自 Linux 内核 `drivers/hid/hid-xinmeng.c`（2025 年合入），
/// hidrec 采样确认：`13 0a 01 00 04 05 63 01` → 99% 放电，
/// `13 0a 01 00 04 05 64 11` → 100% 充电。
///
/// 注意：`GetFeature(0x13)` 返回全零，只能被动监听 input report，
/// 因此需要常驻会话（与罗技 HID++ 同样的后台线程模式）。
final class XinmengSession {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 64)

    private(set) var level: Int?
    private(set) var charging = false
    private(set) var lastReport: Date?
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
        guard data[0] == 0x13, length >= 8 else { return }   // 其余是心跳 / LED 状态报文
        let capacity = Int(data[6])
        // 0% 是键盘休眠时发出的占位报文，不是真实电量（内核驱动样例中真实电量恒 >= 1%）
        guard (1...100).contains(capacity) else { return }
        // 报文带校验和：最后一个字节 = 前面所有字节之和的低 8 位
        // （内核 hidrec 21 字节样本验证：13 0a 01 00 04 05 63 01 …8b / …64 11…9c）
        // macOS 上短报文（8 字节）不带校验和，跳过验证
        if length > 8 {
            let sum = data.prefix(length - 1).reduce(0 as UInt8) { $0 &+ $1 }
            guard sum == data[length - 1] else { return }
        }
        level = capacity
        charging = data[7] == 0x10 || data[7] == 0x11
        lastReport = Date()
    }

    func snapshot() -> [DeviceBattery] {
        // 会话创建失败时不产出设备（避免展示一个必然无读数的假行）
        guard failureReason == nil else { return [] }
        let name = "新盟键盘（2.4G）"
        var extra = ["接收器": String(format: "VID 0x3554 PID 0x%04X", receiverPID)]
        if let date = lastReport {
            let seconds = Int(Date().timeIntervalSince(date))
            extra["报文"] = seconds < 60 ? "\(max(seconds, 1)) 秒前" : "\(seconds / 60) 分钟前"
        }
        return [DeviceBattery(
            id: "xinmeng-2.4g",
            name: name,
            kind: .keyboard,
            transport: .usb,
            level: level,
            charging: charging,
            connected: true,
            source: .vendorHID,
            detail: level == nil ? "已找到接收器，等待电量报文" : "厂商私有协议 0x13",
            lastUpdate: lastReport ?? Date(),
            stale: level != nil && (lastReport == nil || Date().timeIntervalSince(lastReport!) > 300),
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
            let status = self.session?.failureReason
            self.lastStatus = status
            DispatchQueue.main.async { completion(devices, status) }
        }
    }
}
