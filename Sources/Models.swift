import Foundation

/// 设备与 Mac 的连接方式
enum Transport: String, Codable {
    case logitechReceiver = "USB 接收器"
    case bluetooth = "蓝牙"
    case ble = "蓝牙低功耗"
    case usb = "USB"
    case hid = "HID"

    var short: String {
        switch self {
        case .logitechReceiver: return "接收器"
        case .bluetooth: return "蓝牙"
        case .ble: return "BLE"
        case .usb: return "USB"
        case .hid: return "HID"
        }
    }
}

/// 设备类型，决定图标
enum DeviceKind: String, Codable {
    case keyboard, mouse, headset, trackpad, gamepad, speaker, other

    static func infer(from name: String, usage: Int? = nil) -> DeviceKind {
        let n = name.lowercased()
        if n.contains("keyboard") || n.contains("键盘") || n.contains("keys") { return .keyboard }
        if n.contains("mouse") || n.contains("鼠标") || n.contains("triathlon") { return .mouse }
        if n.contains("headset") || n.contains("headphone") || n.contains("airpods") ||
            n.contains("earphone") || n.contains("耳机") || n.contains("buds") ||
            n.contains("beats") || n.contains("freelace") || n.contains("haylou") { return .headset }
        if n.contains("trackpad") || n.contains("触控板") { return .trackpad }
        if n.contains("gamepad") || n.contains("controller") { return .gamepad }
        if n.contains("speaker") || n.contains("音箱") { return .speaker }
        if let u = usage {
            switch u {
            case 0x06: return .keyboard
            case 0x02: return .mouse
            case 0x05: return .gamepad
            default: break
            }
        }
        return .other
    }
}

enum BatterySource: String, Codable {
    case logitechHIDPP = "HID++"
    case systemProfiler = "系统蓝牙"
    case hidProperty = "HID 属性"
    case bleGATT = "BLE 电池服务"
    /// IOBluetooth 私有属性（batteryPercentSingle 等），macOS 设置里的耳机电量就来自这里
    case ioBluetooth = "蓝牙上报"
    case none = "未上报"
}

struct DeviceBattery: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: DeviceKind
    var transport: Transport
    /// 0...100，nil 表示设备当前不向系统上报电量
    var level: Int?
    var charging: Bool = false
    var connected: Bool = true
    var source: BatterySource = .none
    /// 附加说明，例如左右耳分别电量、电压
    var detail: String?
    var lastUpdate: Date = Date()
    /// true 表示本次刷新没读到，显示的是上一次的有效值
    var stale: Bool = false
    var extra: [String: String] = [:]

    /// 精简显示名：去掉「Wireless Keyboard」这类冗余后缀，完整名在提示中可见
    var displayName: String {
        var text = name
        for suffix in [" Wireless Keyboard", " Multi-Device Keyboard",
                       " Multi-Device Mouse", " Wireless Mouse",
                       " Wireless Trackpad", " Multi-Device Trackpad"] {
            if text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        }
        return text
    }

    var levelText: String {
        guard let level = level else { return "—" }
        return "\(level)%"
    }

    var batteryColor: BatteryLevelStyle {
        guard let level = level else { return .unknown }
        if charging { return .charging }
        if level <= 15 { return .critical }
        if level <= 35 { return .low }
        return .healthy
    }

    var sortKey: (Int, String) {
        let rank: Int
        switch kind {
        case .keyboard: rank = 0
        case .mouse: rank = 1
        case .headset: rank = 2
        case .trackpad: rank = 3
        case .gamepad: rank = 4
        case .speaker: rank = 5
        case .other: rank = 6
        }
        return (rank, name)
    }
}

enum BatteryLevelStyle {
    case healthy, low, critical, charging, unknown
}

extension Array where Element == DeviceBattery {
    /// 用于菜单栏展示：有读数设备中的最低电量
    var lowestKnownLevel: Int? {
        compactMap { $0.level }.min()
    }
}
