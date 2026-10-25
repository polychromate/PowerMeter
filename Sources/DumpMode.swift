import Foundation
import AppKit

/// 命令行诊断模式：`PowerMeter --dump` 会在终端打印各数据源的抓取结果，
/// 便于排查某台设备读不到电量的原因。
enum DumpMode {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("PowerMeter 诊断模式")
        print(String(repeating: "=", count: 56))

        var lines: [String] = []
        var done = false

        let hid = HIDBatteryScanner.scan()
        report(title: "通用 HID 属性（BatteryPercent）", devices: hid)

        let logitech = LogitechProvider()
        var remaining = 2
        logitech.snapshot { devices, fatal in
            report(title: "罗技 HID++（接收器 / 直连）", devices: devices, extra: fatal)
            remaining -= 1
            if remaining == 0 { done = true }
        }

        BluetoothBatteryScanner.scan { devices, error in
            report(title: "系统蓝牙（system_profiler）", devices: devices, extra: error)
            remaining -= 1
            if remaining == 0 { done = true }
        }

        remaining += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let result = IOBluetoothBatteryScanner.scan()
            DispatchQueue.main.async {
                report(title: "蓝牙上报（IOBluetooth batteryPercent）", devices: result.0, extra: result.1)
                remaining -= 1
                if remaining == 0 { done = true }
            }
        }

        let deadline = Date().addingTimeInterval(8)
        while !done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !done { print("\n（部分数据源超时未返回）") }
        print(String(repeating: "=", count: 56))
        print("提示：耳机类设备电量优先取 IOBluetooth 的 batteryPercent*（与系统设置一致）；\n     若所有通道都没有数据，才会显示「未知」。")
        _ = lines
    }

    private static func report(title: String, devices: [DeviceBattery], extra: String? = nil) {
        print("\n▸ \(title)")
        if let extra = extra { print("  说明：\(extra)") }
        if devices.isEmpty {
            print("  （无）")
            return
        }
        for device in devices {
            let level = device.level.map { "\($0)%" } ?? "未知"
            let charge = device.charging ? "  ⚡充电中" : ""
            print("  · \(device.name)  [\(device.transport.rawValue)]  \(level)\(charge)")
            if let detail = device.detail { print("      \(detail)") }
        }
    }
}
