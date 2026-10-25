import Foundation

/// 应用版本（与 Info.plist 保持同源）
enum AppVersion {
    static var text: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        // 直接在 bundle 里执行二进制（--dump / --snapshot）时，Bundle.main 未必是 .app
        var url = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        for _ in 0..<4 {
            url.deleteLastPathComponent()
            let plist = url.appendingPathComponent("Contents/Info.plist")
            if let dict = NSDictionary(contentsOf: plist),
               let version = dict["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return "dev"
    }
}

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
    case keyboard, mouse, headset, trackpad, gamepad, speaker, microphone, other

    static func infer(from name: String, usage: Int? = nil) -> DeviceKind {
        let n = name.lowercased()
        if n.contains("keyboard") || n.contains("键盘") || n.contains("keys") ||
            n.contains("a99") || n.contains("xinmeng") || n.contains("新盟") { return .keyboard }
        if n.contains("mouse") || n.contains("鼠标") || n.contains("triathlon") ||
            n.contains("inphic") || n.contains("in9") { return .mouse }
        if n.contains("headset") || n.contains("headphone") || n.contains("airpods") ||
            n.contains("earphone") || n.contains("耳机") || n.contains("buds") ||
            n.contains("beats") || n.contains("freelace") || n.contains("haylou") { return .headset }
        if n.contains("dji mic") || n.contains("mic mini") || n.contains("microphone") ||
            n.contains("麦克风") { return .microphone }
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
    /// 厂商私有 HID 协议（新盟 2.4G 接收器等）
    case vendorHID = "厂商协议"
    case none = "未上报"
}

/// 电池类型：内置锂电（可充电） vs 可更换电池（AA/AAA/纽扣）
enum BatteryChemistry: String, Codable, CaseIterable {
    case lithium
    case replaceable
    case unknown

    /// 界面上的标签文案；unknown 不显示标签，避免制造无根据的结论
    var tag: String? {
        switch self {
        case .lithium: return "锂电池"
        case .replaceable: return "换电池"
        case .unknown: return nil
        }
    }

    var summary: String {
        switch self {
        case .lithium: return "内置锂电，需要充电"
        case .replaceable: return "可更换电池，电量耗尽后换新电池"
        case .unknown: return "类型未知"
        }
    }
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

    /// 电池类型与判定依据（依据显示在悬浮提示里，方便纠正误判）
    var chemistry: BatteryChemistry = .unknown
    var chemistryReason: String = ""

    /// 低电量提醒阈值：未充电的锂电池设备低于此值即视为需要充电
    static let lowBatteryThreshold = 15

    /// 是否需要立刻充电：锂电池 + 未充电 + 电量低于阈值
    var isCritical: Bool {
        guard chemistry == .lithium, !charging, let level = level else { return false }
        return level < DeviceBattery.lowBatteryThreshold
    }

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
        case .microphone: rank = 6
        case .other: rank = 7
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

    /// 菜单栏优先展示的设备。
    ///
    /// 优先级：未充电的锂电池设备 → 充电中的锂电池设备 → 其它有读数的设备；
    /// 同一层级取电量最低的一台（电量相同按设备类型排序，保证顺序稳定）。
    /// 可更换电池设备（AA/AAA）没电只是换节电池，不该抢占菜单栏位置。
    var menuBarCandidate: DeviceBattery? {
        let known = filter { $0.level != nil }
        guard !known.isEmpty else { return nil }
        let tiers: [[DeviceBattery]] = [
            known.filter { $0.chemistry == .lithium && !$0.charging },
            known.filter { $0.chemistry == .lithium },
            known
        ]
        for tier in tiers where !tier.isEmpty {
            if let best = tier.min(by: { a, b in
                if a.level != b.level { return (a.level ?? 100) < (b.level ?? 100) }
                return a.sortKey < b.sortKey
            }) {
                return best
            }
        }
        return nil
    }
}
