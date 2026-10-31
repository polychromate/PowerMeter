import Foundation
import AppKit

/// 命令行诊断模式：打印内置数据源和独立插件的抓取结果。
@MainActor
enum DumpMode {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("PowerMeter \(AppVersion.text) 诊断模式")
        print(String(repeating: "=", count: 56))

        let hid = HIDBatteryScanner.scan()
        report(title: "通用 HID（系统属性 / Battery Strength）", devices: hid)

        var remaining = 3
        BluetoothBatteryScanner.scan { devices, error in
            report(title: "系统蓝牙（system_profiler）", devices: devices, extra: error)
            remaining -= 1
        }

        let plugins = PluginManager()
        plugins.reload()
        if plugins.descriptors.isEmpty {
            print("\n▸ 外部设备插件\n  （未安装；目录：\(PluginInstaller.pluginsDirectory().path)）")
        }
        plugins.snapshotAll { devices, statuses in
            report(title: "外部设备插件（\(plugins.descriptors.count) 个）", devices: devices,
                   extra: statuses.isEmpty ? nil : statuses.joined(separator: "；"))
            remaining -= 1
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = IOBluetoothBatteryScanner.scan()
            DispatchQueue.main.async {
                report(title: "蓝牙上报（IOBluetooth batteryPercent）", devices: result.0, extra: result.1)
                remaining -= 1
            }
        }

        let deadline = Date().addingTimeInterval(14)
        while remaining > 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if remaining > 0 { print("\n（部分数据源超时未返回）") }
        print(String(repeating: "=", count: 56))
        print("系统电量默认优先；标准 HID / BLE 直读兜底；高精度设备插件可声明优先。")
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
            let verdict = BatteryClassifier.classify(device)
            let tag = verdict.chemistry.tag.map { "  [\($0)]" } ?? "  [类型未知]"
            print("  · \(device.name)  [\(device.transport.rawValue)]  \(level)\(charge)\(tag)")
            if let detail = device.detail { print("      \(detail)") }
            print("      类型依据：\(verdict.reason)")
        }
    }
}
