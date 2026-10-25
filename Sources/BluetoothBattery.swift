import Foundation

/// 系统蓝牙源：解析 `system_profiler SPBluetoothDataType -json`。
/// 能读到 AirPods / Beats 等向 macOS 上报电量的蓝牙设备（含左右耳与充电盒）。
enum BluetoothBatteryScanner {

    /// macOS 上位于 /usr/sbin，个别版本在 /usr/bin
    private static var profilerPath: String {
        for candidate in ["/usr/sbin/system_profiler", "/usr/bin/system_profiler"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/sbin/system_profiler"
    }

    static func scan(completion: @escaping ([DeviceBattery], String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: profilerPath)
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion([], "无法调用 system_profiler：\(error.localizedDescription)") }
                return
            }

            // 兜底超时，避免 system_profiler 卡住
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion([], "解析蓝牙信息失败") }
                return
            }

            let devices = parse(json)
            DispatchQueue.main.async { completion(devices, nil) }
        }
    }

    private static func parse(_ json: [String: Any]) -> [DeviceBattery] {
        guard let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [DeviceBattery] = []

        for controller in controllers {
            // 只取「已连接」列表；device_not_connected 里的设备不展示
            guard let connected = controller["device_connected"] else { continue }

            // macOS 上通常是 [{ "设备名": {...} }, ...]，个别版本是 { "设备名": {...} }
            var entries: [(String, [String: Any])] = []
            if let array = connected as? [[String: Any]] {
                for item in array {
                    for (name, props) in item {
                        if let props = props as? [String: Any] {
                            entries.append((name, props))
                        }
                    }
                }
            } else if let dict = connected as? [String: Any] {
                for (name, props) in dict {
                    if let props = props as? [String: Any] {
                        entries.append((name, props))
                    }
                }
            }

            for (name, props) in entries {
                let address = (props["device_address"] as? String) ?? name
                if let device = makeDevice(name: name, address: address, props: props) {
                    devices.append(device)
                }
            }
        }

        var unique: [String: DeviceBattery] = [:]
        for device in devices { unique[device.id] = device }
        return Array(unique.values)
    }

    private static func makeDevice(name: String, address: String, props: [String: Any]) -> DeviceBattery? {
        guard !name.isEmpty, !name.hasPrefix("_") else { return nil }

        let minorType = (props["device_minorType"] as? String) ?? ""
        var kind: DeviceKind
        switch minorType {
        case "Headset", "Headphones": kind = .headset
        case "Keyboard": kind = .keyboard
        case "Mouse": kind = .mouse
        case "Trackpad": kind = .trackpad
        case "Gaming Controller", "Gamepad": kind = .gamepad
        default: kind = DeviceKind.infer(from: name)
        }

        // 电量字段：device_batteryLevelMain / Left / Right / Case / device_batteryLevel
        var main: Int?
        var extras: [String] = []
        for (key, value) in props where key.lowercased().contains("batterylevel") {
            guard let text = value as? String else { continue }
            let digits = text.filter { $0.isNumber }
            guard let percent = Int(digits), (0...100).contains(percent) else { continue }
            if key.hasSuffix("Main") || key == "device_batteryLevel" {
                main = percent
            } else if key.hasSuffix("Left") {
                extras.append("左 \(percent)%")
            } else if key.hasSuffix("Right") {
                extras.append("右 \(percent)%")
            } else if key.hasSuffix("Case") {
                extras.append("仓 \(percent)%")
            } else {
                main = main ?? percent
            }
        }

        // 没有 minorType 且无法归类为外设的（其它 Mac、手机等）不展示
        if minorType.isEmpty && kind == .other { return nil }

        let rssi = (props["device_rssi"] as? String) ?? ""
        var detail: String
        if main == nil {
            detail = "该设备未向系统上报电量"
        } else {
            detail = "蓝牙上报"
            if !extras.isEmpty { detail += " · " + extras.joined(separator: " / ") }
        }

        return DeviceBattery(
            id: "bt-\(address)",
            name: name,
            kind: kind,
            transport: .bluetooth,
            level: main,
            connected: true,
            source: main == nil ? .none : .systemProfiler,
            detail: detail,
            lastUpdate: Date(),
            extra: ["类型": minorType.isEmpty ? "未知" : minorType] .merging(rssi.isEmpty ? [:] : ["RSSI": rssi + " dBm"]) { a, _ in a }
        )
    }
}
