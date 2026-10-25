import Foundation
import IOKit
import IOKit.hid

/// 通用 HID 电量源：适用于向系统上报 `BatteryPercent` 属性的设备
/// （苹果妙控系列、部分蓝牙键鼠、带电池上报的 HID 设备）。
enum HIDBatteryScanner {

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        if let n = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber { return n.intValue }
        return nil
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
            let level = int(device, "BatteryPercent")
            guard let level = level, (0...100).contains(level) else { continue }
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
                detail: "HID BatteryPercent",
                lastUpdate: Date()
            ))
        }
        return results
    }
}
