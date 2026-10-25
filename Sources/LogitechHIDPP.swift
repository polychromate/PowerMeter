import Foundation
import IOKit
import IOKit.hid

/// 与罗技 HID++ 设备（Unifying / Bolt 接收器，或直接蓝牙连接的罗技外设）通信。
///
/// 协议要点：
/// - 7 字节短报文：`[0x10, devIndex, featureIndex, (function << 4) | swId, p0, p1, p2]`
/// - 20 字节长报文用 report ID `0x11`
/// - `IRoot`（featureIndex 0x00）的 function 0 = getFeature，function 1 = ping（返回 0xAA 魔数）
/// - 电量：0x1000 BATTERY_LEVEL_STATUS → 0x1004 UNIFIED_BATTERY → 0x1001 BATTERY_VOLTAGE
final class HIDPPSession {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var inbox: [[UInt8]] = []
    private let swId: UInt8 = 0x01
    /// 特征索引是「每台设备」独立的，必须按槽位分别缓存
    private var featureCache: [UInt8: [UInt16: UInt8]] = [:]
    private var nameCache: [UInt8: String] = [:]
    private(set) var isReceiver = false

    /// 必须在将要运行 runloop 的线程上创建
    init?() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
            kIOHIDPrimaryUsageKey: 0x01
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return nil }

        // 优先选接收器（名字里带 Receiver），否则取第一个直连设备
        let sorted = set.sorted { (a, b) -> Bool in
            let an = (IOHIDDeviceGetProperty(a, kIOHIDProductKey as CFString) as? String) ?? ""
            let bn = (IOHIDDeviceGetProperty(b, kIOHIDProductKey as CFString) as? String) ?? ""
            return an.contains("Receiver") && !bn.contains("Receiver")
        }
        guard let dev = sorted.first else { return nil }

        let productName = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? ""
        isReceiver = productName.localizedCaseInsensitiveContains("receiver")

        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        manager = mgr
        device = dev

        IOHIDDeviceRegisterInputReportCallback(dev, &buffer, 64, { context, _, _, _, _, report, length in
            guard let context = context else { return }
            let session = Unmanaged<HIDPPSession>.fromOpaque(context).takeUnretainedValue()
            session.inbox.append((0..<length).map { report[$0] })
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

    // MARK: - 底层收发

    private func call(devIndex: UInt8, feature: UInt8, function: UInt8,
                      params: [UInt8], timeout: TimeInterval = 0.35) -> [UInt8]? {
        guard let device = device else { return nil }
        inbox.removeAll()
        var packet: [UInt8] = [0x10, devIndex, feature, (function << 4) | swId]
        packet.append(contentsOf: params)
        while packet.count < 7 { packet.append(0) }
        var output = Array(packet.prefix(7))

        let rc = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x10, &output, output.count)
        if rc != kIOReturnSuccess { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.008, false)
            for report in inbox where report.count >= 5 {
                // 错误报文：featureIndex 为 0x8F
                if report[1] == devIndex && report[2] == 0x8F { return nil }
                if report[1] == devIndex && report[2] == feature && (report[3] & 0x0F) == swId {
                    return report
                }
            }
        }
        return nil
    }

    private func featureIndex(_ featureId: UInt16, devIndex: UInt8) -> UInt8? {
        if let cached = featureCache[devIndex]?[featureId] { return cached }
        guard let report = call(devIndex: devIndex, feature: 0x00, function: 0x00,
                               params: [UInt8(featureId >> 8), UInt8(featureId & 0xFF), 0]),
              report.count > 4, report[4] != 0 else { return nil }
        featureCache[devIndex, default: [:]][featureId] = report[4]
        return report[4]
    }

    // MARK: - 设备枚举

    /// 接收器上可探测的设备槽位；直连蓝牙设备固定为 0xFF
    private var slotRange: [UInt8] {
        isReceiver ? Array(1...6) : [0xFF]
    }

    private func isAlive(_ slot: UInt8) -> Bool {
        // ping：function 1，参数 0x00 0x00 0xAA
        guard let report = call(devIndex: slot, feature: 0x00, function: 0x01,
                               params: [0x00, 0x00, 0xAA], timeout: 0.22) else { return false }
        return report.contains(0xAA)
    }

    func deviceName(_ slot: UInt8) -> String? {
        if let cached = nameCache[slot] { return cached }
        guard let index = featureIndex(0x0005, devIndex: slot) else { return nil }
        guard let lengthReport = call(devIndex: slot, feature: index, function: 0x00, params: [0, 0, 0]),
              lengthReport.count > 4 else { return nil }
        let total = Int(lengthReport[4])
        guard total > 0, total <= 64 else { return nil }

        var name = ""
        var offset = 0
        while offset < total {
            guard let chunk = call(devIndex: slot, feature: index, function: 0x01,
                                  params: [UInt8(offset), 0, 0]), chunk.count > 4 else { break }
            let slice = chunk[4...].prefix(total - name.utf8.count).filter { $0 != 0 }
            name += String(bytes: slice, encoding: .utf8) ?? ""
            offset += 16
        }
        guard !name.isEmpty else { return nil }
        nameCache[slot] = name
        return name
    }

    struct BatteryReading {
        var level: Int
        var charging: Bool
        var detail: String
    }

    private var transportLabel: String { isReceiver ? "接收器直读" : "蓝牙直读" }

    /// 0x1000 / 0x1004 的充电状态枚举（0=放电，1=充电，2=即将充满，3=充满，4=慢充）
    private static func statusName(_ status: Int) -> String {
        switch status {
        case 0: return "放电中"
        case 1: return "充电中"
        case 2: return "即将充满"
        case 3: return "已充满"
        case 4: return "慢速充电"
        case 5: return "电池类型异常"
        case 6: return "温度异常"
        case 7: return "充电故障"
        default: return "状态未知"
        }
    }

    /// 0x1004 的粗粒度档位 → 百分比
    private static func bucketPercent(_ bucket: Int) -> Int {
        switch bucket {
        case 1: return 5      // Critical
        case 2: return 25     // Low
        case 4: return 70     // Good
        case 8: return 100    // Full
        default: return 50
        }
    }

    func battery(_ slot: UInt8) -> BatteryReading? {
        // 0x1000 BATTERY_LEVEL_STATUS：report[4]=电量% report[5]=下一档位 report[6]=充电状态
        if let index = featureIndex(0x1000, devIndex: slot),
           let report = call(devIndex: slot, feature: index, function: 0x00, params: [0, 0, 0]),
           report.count > 6 {
            let level = Int(report[4])
            let status = Int(report[6])
            if level <= 100, status <= 7 {
                // 1=充电中 2=即将充满 4=慢速充电 都算在充电
                let charging = [1, 2, 4].contains(status)
                let effective = status == 3 ? 100 : level
                return BatteryReading(level: effective, charging: charging,
                                      detail: "HID++ 0x1000 · \(Self.statusName(status))")
            }
        }
        // 0x1004 UNIFIED_BATTERY：fn0=能力，fn1=电量；report[4]=百分比 report[5]=档位 report[6]=充电状态
        if let index = featureIndex(0x1004, devIndex: slot) {
            let caps = call(devIndex: slot, feature: index, function: 0x00, params: [0, 0, 0])
            let hasPercent = caps.map { $0.count > 5 && ($0[5] & 0x02) != 0 } ?? false
            if let info = call(devIndex: slot, feature: index, function: 0x01, params: [0, 0, 0]),
               info.count > 6 {
                let status = Int(info[6])
                if status <= 7 {
                    let charging = [1, 2, 4].contains(status)
                    var level = hasPercent ? Int(info[4]) : Self.bucketPercent(Int(info[5]))
                    if status == 3 { level = 100 }
                    return BatteryReading(level: min(100, max(0, level)), charging: charging,
                                          detail: "HID++ 0x1004 · \(Self.statusName(status))")
                }
            }
        }
        // 0x1001 BATTERY_VOLTAGE：毫伏 → 百分比（单节锂电 3450–4200mV / 2×AA 2000–3000mV）
        if let index = featureIndex(0x1001, devIndex: slot),
           let report = call(devIndex: slot, feature: index, function: 0x00, params: [0, 0, 0]),
           report.count > 6 {
            let millivolts = Int(report[4]) | Int(report[5]) << 8
            guard millivolts > 0 else { return nil }
            let (low, high) = millivolts < 3300 ? (1800, 3000) : (3450, 4200)
            let percent = min(100, max(0, (millivolts - low) * 100 / (high - low)))
            // 0x1001 的第二个字节偶尔带充电标志（0x80 = 充电中）
            let flags = Int(report[6])
            return BatteryReading(level: percent, charging: (flags & 0x80) != 0,
                                  detail: "\(millivolts) mV（电压换算）")
        }
        return nil
    }

    /// 读取该接收器/直连设备下的所有设备
    func scan() -> [DeviceBattery] {
        var results: [DeviceBattery] = []
        for slot in slotRange {
            guard isAlive(slot) else {
                nameCache.removeValue(forKey: slot)
                continue
            }
            guard let name = deviceName(slot) else { continue }
            let reading = battery(slot)
            let kind = DeviceKind.infer(from: name)
            let id = "logitech-\(isReceiver ? "receiver" : "direct")-\(slot)-\(name)"
            results.append(DeviceBattery(
                id: id,
                name: name,
                kind: kind,
                transport: isReceiver ? .logitechReceiver : .bluetooth,
                level: reading?.level,
                charging: reading?.charging ?? false,
                connected: true,
                source: reading == nil ? .none : .logitechHIDPP,
                detail: reading.map { r in
                    r.charging ? "\(transportLabel) · 充电中" : transportLabel
                } ?? "已连接，本次未读到电量（设备休眠）",
                lastUpdate: Date(),
                extra: ["协议": reading?.detail ?? "HID++"]
            ))
        }
        return results
    }
}

/// 在独立线程上持有 HID++ 会话，避免阻塞主线程的 runloop。
final class LogitechProvider {
    private let lock = NSLock()
    private var queue: [() -> Void] = []
    private var thread: Thread?
    private var session: HIDPPSession?
    private var lastFatal: String?

    private func ensureThread() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.runloop() }
        t.name = "PowerMeter.HIDPP"
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
        // 会话必须在本线程创建，回调才会调度到本线程 runloop
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
            if self.session == nil {
                self.session = HIDPPSession()
                if self.session == nil {
                    self.lastFatal = "未找到罗技接收器或 HID++ 接口"
                } else {
                    self.lastFatal = nil
                }
            }
            let devices = self.session?.scan() ?? []
            let fatal = self.lastFatal
            DispatchQueue.main.async { completion(devices, fatal) }
        }
    }
}
