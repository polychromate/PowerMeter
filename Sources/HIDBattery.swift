import Foundation
import IOKit
import IOKit.hid

/// 通用 HID 电量源，两条通道：
///
/// 1. IOKit 的 `BatteryPercent` 属性（苹果妙控系列、部分设备）
/// 2. HID 报告描述符里的 **Battery Strength** 元素（usage page 0x0006 / usage 0x0020）。
///    多数蓝牙键鼠（如罗技 K380）走的是这条：macOS 不会把它们映射成
///    `BatteryPercent` 属性，但报告描述符里确实有这个元素，可以用 GET_REPORT 主动读取。
///    实测：`Keyboard K380` → report ID 3，报文 `03 09`，逻辑量程 0..20 → 45%。
enum HIDBatteryScanner {

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        if let n = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber { return n.intValue }
        return nil
    }

    /// HID Battery Strength 元素所在页 / usage
    private static let batteryPage: UInt32 = 0x0006
    private static let batteryUsage: UInt32 = 0x0020

    /// 读取 Battery Strength 元素：主动 GET_REPORT，再用 IOKit 自己解析字节与量程。
    /// 返回值 0...100，nil 表示读不到。
    private static func readBatteryStrength(_ device: IOHIDDevice) -> Int? {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
              let element = elements.first(where: {
                  IOHIDElementGetUsagePage($0) == batteryPage && IOHIDElementGetUsage($0) == batteryUsage
              }) else { return nil }

        let reportID = Int(IOHIDElementGetReportID(element))
        var buffer = [UInt8](repeating: 0, count: 64)
        var length: CFIndex = 64
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(reportID), &buffer, &length) == kIOReturnSuccess,
              length > 0 else { return nil }

        // 报文首字节是 report ID（ID 为 0 时没有），元素字节从其后开始
        let start = reportID == 0 ? 0 : 1
        guard length > start else { return nil }
        let body = Array(buffer[start..<Int(length)])
        guard let value = IOHIDValueCreateWithBytes(kCFAllocatorDefault, element, 0, body, CFIndex(body.count)) else { return nil }

        let raw = Double(IOHIDValueGetIntegerValue(value))
        let min = Double(IOHIDElementGetLogicalMin(element))
        let max = Double(IOHIDElementGetLogicalMax(element))
        // 量程不一定到 100（K380 是 0..20），按线性比例折算成百分比
        let percent: Double
        if max > min {
            percent = (raw - min) * 100.0 / (max - min)
        } else {
            percent = raw
        }
        return (0...100).contains(Int(percent.rounded())) ? Int(percent.rounded()) : nil
    }

    static func scan() -> [DeviceBattery] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        var results: [DeviceBattery] = []
        var seen = Set<String>()

        for device in devices {
            guard let name = string(device, kIOHIDProductKey), !name.isEmpty else { continue }

            let transportRaw = string(device, kIOHIDTransportKey) ?? ""
            // 排除机身内部总线设备
            if transportRaw == "SPMI" || transportRaw == "SPU" { continue }

            let transport: Transport
            switch transportRaw {
            case "Bluetooth": transport = .bluetooth
            case "BluetoothLowEnergy": transport = .ble
            case "USB": transport = .usb
            default: transport = .hid
            }

            let key = "\(name)-\(transport.rawValue)"
            guard !seen.contains(key) else { continue }

            // 通道一：IOKit 的 BatteryPercent 属性
            var level = int(device, "BatteryPercent").flatMap { (0...100).contains($0) ? $0 : nil }
            var detail = "HID BatteryPercent"

            // 通道二：HID 报告里的 Battery Strength 元素（蓝牙键鼠的主要通道）
            if level == nil {
                // 打开设备才能发 GET_REPORT；用 kIOHIDOptionsTypeNone，绝不 seize，避免抢走键盘输入
                if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                    defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
                    if let value = readBatteryStrength(device) {
                        level = value
                        detail = "HID 电量元素 Battery Strength"
                    }
                }
            }
            guard let level = level else { continue }
            seen.insert(key)

            let usage = int(device, kIOHIDPrimaryUsageKey)
            let flags = int(device, "BatteryStatusFlags") ?? 0
            results.append(DeviceBattery(
                id: "hid-\(key)",
                name: name,
                kind: DeviceKind.infer(from: name, usage: usage),
                transport: transport,
                level: level,
                charging: (flags & 0x01) != 0,
                connected: true,
                source: .hidProperty,
                detail: detail,
                lastUpdate: Date()
            ))
        }
        return results
    }
}
