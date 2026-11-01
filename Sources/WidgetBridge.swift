import Foundation

/// 桌面小组件的数据桥。
///
/// 小组件跑在沙盒里，读不到本程序的应用支持目录，所以这里把电量同时写到两个位置：
/// 1. 自己的 `~/Library/Application Support/PowerMeter/widget.json`，方便排查；
/// 2. 小组件容器的同一相对路径——主程序没有沙盒，有权限写进去，小组件读自己的容器也不需要授权。
@MainActor
enum WidgetBridge {
    static let widgetBundleID = "com.chenge.PowerMeter.Widget"

    /// 上一次写入内容的指纹，内容没变就不重复落盘
    private static var lastSignature = ""

    static func write(devices: [DeviceBattery], primary: DeviceBattery?) {
        let rows: [[String: Any]] = devices.map { device in
            [
                "name": device.name,
                "kind": device.kind.rawValue,
                "level": device.level as Any,
                "charging": device.charging,
                "chemistry": device.chemistry.rawValue,
                "transport": device.transport.short,
                "stale": device.stale
            ]
        }

        let payload: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "primary": primary?.name ?? NSNull(),
            "devices": rows
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let signature = String(data: data, encoding: .utf8) ?? ""
        guard signature != lastSignature else { return }
        lastSignature = signature

        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [
            home.appendingPathComponent("Library/Application Support/PowerMeter", isDirectory: true),
            home.appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support/PowerMeter",
                                        isDirectory: true)
        ]

        for directory in directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("widget.json"))
        }
    }
}
