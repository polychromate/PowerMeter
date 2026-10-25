import Foundation

/// 判断设备用的是「内置锂电」还是「可更换电池」。
///
/// 判定依据按可靠性从高到低：
/// 1. 用户覆盖文件 `~/Library/Application Support/PowerMeter/battery-types.json`
/// 2. 观测到充电状态 —— 只有可充电电池才可能报 charging
/// 3. 罗技 `0x1001` 电压读数 —— 2×AA/AAA 的电压上限（3.2V）远低于单节锂电（3.0–4.2V）
/// 4. 已知型号库
/// 5. 设备类型兜底：耳机、触控板几乎都是内置锂电
///
/// 判断不出来就返回 `.unknown`，界面不显示标签 —— 宁可不说，也不给错信息。
enum BatteryClassifier {

    struct Verdict: Equatable {
        var chemistry: BatteryChemistry
        var reason: String
    }

    // MARK: - 已知型号库

    private struct Rule {
        let pattern: String
        let chemistry: BatteryChemistry
        let reason: String
    }

    /// 长模式优先匹配，避免短模式抢走更精确的规则
    private static let rules: [Rule] = [
        // ---------- 内置锂电（可充电） ----------
        Rule(pattern: "mx keys", chemistry: .lithium, reason: "罗技 MX Keys 系列为内置锂电"),
        Rule(pattern: "mx mechanical", chemistry: .lithium, reason: "MX Mechanical 为内置锂电"),
        Rule(pattern: "mx master", chemistry: .lithium, reason: "MX Master 系列为内置锂电"),
        Rule(pattern: "mx anywhere", chemistry: .lithium, reason: "MX Anywhere 系列为内置锂电"),
        Rule(pattern: "mx ergo", chemistry: .lithium, reason: "MX Ergo 为内置锂电"),
        Rule(pattern: "mx creative", chemistry: .lithium, reason: "MX Creative Console 为内置锂电"),
        Rule(pattern: "craft", chemistry: .lithium, reason: "罗技 Craft 键盘为内置锂电"),
        Rule(pattern: "g915", chemistry: .lithium, reason: "G915 系列为内置锂电"),
        Rule(pattern: "g913", chemistry: .lithium, reason: "G913 系列为内置锂电"),
        Rule(pattern: "superlight", chemistry: .lithium, reason: "PRO X Superlight 为内置锂电"),
        Rule(pattern: "magic keyboard", chemistry: .lithium, reason: "妙控键盘为内置锂电"),
        Rule(pattern: "magic mouse", chemistry: .lithium, reason: "妙控鼠标为内置锂电"),
        Rule(pattern: "magic trackpad", chemistry: .lithium, reason: "妙控触控板为内置锂电"),
        Rule(pattern: "airpods", chemistry: .lithium, reason: "AirPods 为内置锂电"),
        Rule(pattern: "beats", chemistry: .lithium, reason: "Beats 为内置锂电"),
        Rule(pattern: "haylou", chemistry: .lithium, reason: "HAYLOU 耳机为内置锂电"),
        Rule(pattern: "wh-1000", chemistry: .lithium, reason: "索尼 WH-1000 系列为内置锂电"),
        Rule(pattern: "wf-1000", chemistry: .lithium, reason: "索尼 WF-1000 系列为内置锂电"),
        Rule(pattern: "quietcomfort", chemistry: .lithium, reason: "Bose QuietComfort 为内置锂电"),
        Rule(pattern: "soundcore", chemistry: .lithium, reason: "Soundcore 耳机为内置锂电"),
        Rule(pattern: "freebuds", chemistry: .lithium, reason: "FreeBuds 为内置锂电"),
        Rule(pattern: "jabra", chemistry: .lithium, reason: "Jabra 耳机为内置锂电"),

        // ---------- 可更换电池（AA / AAA） ----------
        Rule(pattern: "m720", chemistry: .replaceable, reason: "M720 Triathlon 使用 1×AA 电池"),
        Rule(pattern: "triathlon", chemistry: .replaceable, reason: "M720 Triathlon 使用 1×AA 电池"),
        Rule(pattern: "m650", chemistry: .replaceable, reason: "M650 使用 1×AA 电池"),
        Rule(pattern: "m750", chemistry: .replaceable, reason: "M750 使用 1×AA 电池"),
        Rule(pattern: "m590", chemistry: .replaceable, reason: "M590 使用 1×AA 电池"),
        Rule(pattern: "m585", chemistry: .replaceable, reason: "M585 使用 1×AA 电池"),
        Rule(pattern: "m535", chemistry: .replaceable, reason: "M535 使用 1×AA 电池"),
        Rule(pattern: "m557", chemistry: .replaceable, reason: "M557 使用 1×AA 电池"),
        Rule(pattern: "m560", chemistry: .replaceable, reason: "M560 使用 1×AA 电池"),
        Rule(pattern: "m525", chemistry: .replaceable, reason: "M525 使用 1×AA 电池"),
        Rule(pattern: "m330", chemistry: .replaceable, reason: "M330 使用 1×AA 电池"),
        Rule(pattern: "m325", chemistry: .replaceable, reason: "M325 使用 1×AA 电池"),
        Rule(pattern: "m310", chemistry: .replaceable, reason: "M310 使用 1×AA 电池"),
        Rule(pattern: "m185", chemistry: .replaceable, reason: "M185 使用 1×AA 电池"),
        Rule(pattern: "m170", chemistry: .replaceable, reason: "M170 使用 1×AA 电池"),
        Rule(pattern: "m100", chemistry: .replaceable, reason: "M100 使用 1×AA 电池"),
        Rule(pattern: "k380", chemistry: .replaceable, reason: "K380 使用 2×AAA 电池"),
        Rule(pattern: "k400", chemistry: .replaceable, reason: "K400 使用 2×AAA 电池"),
        Rule(pattern: "k270", chemistry: .replaceable, reason: "K270 使用 2×AAA 电池"),
        Rule(pattern: "k375", chemistry: .replaceable, reason: "K375s 使用 2×AAA 电池"),
        Rule(pattern: "k780", chemistry: .replaceable, reason: "K780 使用 2×AAA 电池"),
        Rule(pattern: "pop keys", chemistry: .replaceable, reason: "POP Keys 使用 2×AAA 电池"),
        Rule(pattern: "pebble", chemistry: .replaceable, reason: "Pebble 系列使用 AA/AAA 电池"),
        Rule(pattern: "g304", chemistry: .replaceable, reason: "G304 使用 1×AA 电池"),
        Rule(pattern: "g305", chemistry: .replaceable, reason: "G305 使用 1×AA 电池"),
        Rule(pattern: "g613", chemistry: .replaceable, reason: "G613 使用 2×AA 电池")
    ].sorted { $0.pattern.count > $1.pattern.count }

    // MARK: - 对外

    static func classify(_ device: DeviceBattery) -> Verdict {
        let name = device.name.lowercased()

        // 1. 用户手动指定优先
        if let hit = overrides().filter({ name.contains($0.key) }).max(by: { $0.key.count < $1.key.count }) {
            return Verdict(chemistry: hit.value, reason: "按 battery-types.json 手动指定")
        }

        // 2. 充电状态是决定性证据
        if device.charging {
            return Verdict(chemistry: .lithium, reason: "检测到充电状态，只可能是可充电电池")
        }

        // 3. 电压落在碱性电池区间
        if let verdict = verdictFromVoltage(device) { return verdict }

        // 4. 已知型号库
        for rule in rules where name.contains(rule.pattern) {
            return Verdict(chemistry: rule.chemistry, reason: rule.reason)
        }

        // 5. 类型兜底
        switch device.kind {
        case .headset:
            return Verdict(chemistry: .lithium, reason: "蓝牙耳机基本都内置锂电")
        case .trackpad:
            return Verdict(chemistry: .lithium, reason: "触控板基本都内置锂电")
        default:
            return Verdict(chemistry: .unknown, reason: "型号不在已知库中，无法判断电池类型")
        }
    }

    /// 从 `extra["电压"]`（形如 `2310 mV`）判断电池类型
    private static func verdictFromVoltage(_ device: DeviceBattery) -> Verdict? {
        guard let text = device.extra["电压"] ?? device.detail,
              let millivolts = leadingInteger(in: text), millivolts > 1000 else { return nil }
        let volts = Double(millivolts) / 1000
        if millivolts <= 3300 {
            return Verdict(chemistry: .replaceable,
                           reason: String(format: "电压 %.2fV，符合 2×AA/AAA 电池", volts))
        }
        if millivolts >= 3400 {
            return Verdict(chemistry: .lithium,
                           reason: String(format: "电压 %.2fV，符合单节锂电", volts))
        }
        return nil
    }

    private static func leadingInteger(in text: String) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - 用户覆盖

    private static let overrideFileName = "battery-types.json"
    private static var overrideCache: [String: BatteryChemistry]?
    private static var overrideLoadedAt = Date.distantPast

    /// 覆盖文件格式：`{ "m720": "replaceable", "mx keys": "lithium" }`
    /// 键按小写子串匹配设备名，命中多个时取最长的键。
    private static func overrides() -> [String: BatteryChemistry] {
        if let cached = overrideCache, Date().timeIntervalSince(overrideLoadedAt) < 5 {
            return cached
        }
        overrideLoadedAt = Date()

        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return [:]
        }
        let url = base.appendingPathComponent("PowerMeter/\(overrideFileName)")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            overrideCache = [:]
            return [:]
        }

        var map: [String: BatteryChemistry] = [:]
        for (key, value) in raw {
            if let chemistry = BatteryChemistry(rawValue: value.lowercased()), chemistry != .unknown {
                map[key.lowercased()] = chemistry
            }
        }
        overrideCache = map
        return map
    }
}
