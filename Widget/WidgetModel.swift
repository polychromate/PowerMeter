import SwiftUI
import WidgetKit

// MARK: - 共享数据

/// 主程序每分钟把电量写进 widget.json，小组件只读这个文件，不自己碰硬件。
struct WidgetDevice: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let kind: String
    let level: Int?
    let charging: Bool
    let chemistry: String
    let transport: String
    let stale: Bool
}

struct WidgetSnapshot: Decodable {
    let updated: String?
    let primary: String?
    let devices: [WidgetDevice]

    static let empty = WidgetSnapshot(updated: nil, primary: nil, devices: [])
}

/// 小组件时间线条目
struct PowerMeterEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

enum WidgetStore {
    /// 小组件跑在沙盒（自己的容器）里，也可能没有沙盒（真实用户目录）。
    /// 两个位置都试一遍，取先读到的。
    static func load() -> WidgetSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/PowerMeter/widget.json"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/PowerMeter/widget.json")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { continue }
            return snapshot
        }
        return .empty
    }

    /// 心跳：扩展每被真正拉起一次就写一行。系统日志读不到时，这是唯一能证明
    /// 「扩展确实跑起来了、不是只注册了个空壳」的外部证据。
    static func heartbeat() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PowerMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()) + "\n"
        let file = dir.appendingPathComponent("widget-heartbeat.txt")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(stamp.utf8))
            try? handle.close()
        } else {
            try? Data(stamp.utf8).write(to: file)
        }
    }
}

extension WidgetSnapshot {
    var primaryDevice: WidgetDevice? {
        if let name = primary, let match = devices.first(where: { $0.name == name }) { return match }
        return devices.first
    }

    var updatedDate: Date? {
        guard let updated else { return nil }
        return ISO8601DateFormatter().date(from: updated)
    }

    func relativeUpdateText() -> String? {
        guard let date = updatedDate else { return nil }
        let seconds = Int(Date().timeIntervalSince(date))
        return seconds < 60 ? "\(max(seconds, 1)) 秒前更新" : "\(seconds / 60) 分钟前更新"
    }

    /// 「1 台设备 · 30 秒前更新」这类脚注
    var deviceFooter: String? {
        guard let time = relativeUpdateText() else { return nil }
        return "\(devices.count) 台设备 · \(time)"
    }
}

// MARK: - 展示辅助

extension WidgetDevice {
    var displayName: String {
        var text = name
        for suffix in [" Wireless Keyboard", " Multi-Device Keyboard", " Multi-Device Mouse",
                       " Wireless Mouse", " Wireless Trackpad", " Multi-Device Trackpad"] {
            if text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        }
        return text
    }

    var symbolName: String {
        switch kind {
        case "keyboard": return "keyboard"
        case "mouse": return "computermouse"
        case "headset": return "headphones"
        case "trackpad": return "rectangle.and.hand.point.up.left"
        case "gamepad": return "gamecontroller"
        case "speaker": return "hifispeaker"
        case "microphone": return "mic.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    var levelText: String {
        guard let level else { return "—" }
        return "\(level)%"
    }

    /// 充电蓝、低电红、偏橙、正常绿——与主程序同一套阈值
    var tint: Color {
        guard let level else { return .secondary }
        if charging { return Color(red: 0.16, green: 0.53, blue: 0.92) }
        if level <= 15 { return Color(red: 0.87, green: 0.26, blue: 0.24) }
        if level <= 35 { return Color(red: 0.93, green: 0.60, blue: 0.13) }
        return Color(red: 0.20, green: 0.72, blue: 0.38)
    }

    var chemistryText: String? {
        switch chemistry {
        case "lithium": return "锂电池"
        case "replaceable": return "换电池"
        default: return nil
        }
    }

    var subtitle: String {
        var parts: [String] = []
        if let tag = chemistryText { parts.append(tag) }
        parts.append(transport)
        return parts.joined(separator: " · ")
    }
}
