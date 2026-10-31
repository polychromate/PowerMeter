import Foundation
import JavaScriptCore
import AppKit

let powerMeterPluginAPIVersion = 1

struct PluginManifest: Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var apiVersion: Int
    var minimumAppVersion: String
    var entry: String
    var author: String?
    var description: String?
    var sourcePolicy: String = "fallback"
}

struct PluginDescriptor: Identifiable, Equatable {
    var id: String
    var name: String
    var version: String
    var path: String
    var status: String
}

enum PluginSourcePolicy: String, Codable {
    case preferPlugin
    case fallback
    case pluginOnly
}

enum PluginInstaller {
    static func pluginsDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["POWERMETER_PLUGIN_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PowerMeter/Plugins", isDirectory: true)
    }

    static func manifest(at bundle: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try validate(manifest, at: bundle)
        return manifest
    }

    static func validate(_ manifest: PluginManifest, at bundle: URL) throws {
        guard manifest.id.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw PluginError.invalid("插件 id 只能包含字母、数字、点和连字符")
        }
        guard manifest.apiVersion == powerMeterPluginAPIVersion else {
            throw PluginError.invalid("插件 API 版本不兼容：需要 \(manifest.apiVersion)，当前为 \(powerMeterPluginAPIVersion)")
        }
        guard compareVersions(AppVersion.text, manifest.minimumAppVersion) >= 0 else {
            throw PluginError.invalid("插件需要 PowerMeter \(manifest.minimumAppVersion) 或更高版本")
        }
        guard !manifest.entry.isEmpty, !manifest.entry.hasPrefix("/"), !manifest.entry.contains("..") else {
            throw PluginError.invalid("插件入口路径无效")
        }
        guard ["preferPlugin", "fallback", "pluginOnly"].contains(manifest.sourcePolicy) else {
            throw PluginError.invalid("未知来源策略：\(manifest.sourcePolicy)")
        }
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent(manifest.entry).path) else {
            throw PluginError.invalid("找不到插件入口：\(manifest.entry)")
        }
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        return 0
    }

    static func install(from source: URL) throws -> PluginManifest {
        let bundle = try materializeBundle(from: source)
        let manifest = try manifest(at: bundle)
        let directory = pluginsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(manifest.id).pmplugin", isDirectory: true)
        if bundle.standardizedFileURL.path == destination.standardizedFileURL.path {
            return manifest
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if bundle.path == source.path {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: bundle, to: destination)
        }
        return manifest
    }

    private static func materializeBundle(from source: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw PluginError.invalid("插件文件不存在")
        }
        if isDirectory.boolValue && source.pathExtension == "pmplugin" {
            return source
        }
        guard source.pathExtension.lowercased() == "zip" else {
            throw PluginError.invalid("请选择 .pmplugin 插件包或其 zip 压缩包")
        }

        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PowerMeter-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", source.path, temporary.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginError.invalid("插件压缩包无法解压")
        }

        var bundles: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "pmplugin" {
                bundles.append(url)
            }
        }
        guard bundles.count == 1 else {
            throw PluginError.invalid("压缩包中必须且只能包含一个 .pmplugin 插件包")
        }
        return bundles[0]
    }
}

enum PluginError: LocalizedError {
    case invalid(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .runtime(let message): return message
        }
    }
}

/// 一个脚本插件在独立线程中运行，JSContext 和 HID 回调始终属于同一个 RunLoop。
private final class PluginInstance {
    let manifest: PluginManifest
    let bundle: URL

    private let lock = NSLock()
    private var queue: [() -> Void] = []
    private var thread: Thread?
    private var context: JSContext?
    private var bridge: PluginHIDBridge?
    private var loadError: String?

    init(manifest: PluginManifest, bundle: URL) {
        self.manifest = manifest
        self.bundle = bundle
    }

    private func ensureThread() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "PowerMeter.Plugin.\(manifest.id)"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    private func enqueue(_ work: @escaping () -> Void) {
        lock.lock()
        queue.append(work)
        lock.unlock()
    }

    private func runLoop() {
        while true {
            lock.lock()
            let pending = queue
            queue.removeAll()
            lock.unlock()
            for work in pending { work() }
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
    }

    private func loadIfNeeded() -> Bool {
        if context != nil { return loadError == nil }
        guard let script = try? String(contentsOf: bundle.appendingPathComponent(manifest.entry), encoding: .utf8) else {
            loadError = "无法读取插件脚本"
            return false
        }
        let context = JSContext()!
        let bridge = PluginHIDBridge()
        context.setObject(bridge, forKeyedSubscript: "hid" as NSString)
        context.setObject(["id": manifest.id, "apiVersion": powerMeterPluginAPIVersion], forKeyedSubscript: "powermeter" as NSString)
        context.setObject({ (message: String) in
            NSLog("[PowerMeter plugin] %@", message)
        } as @convention(block) (String) -> Void, forKeyedSubscript: "log" as NSString)
        context.exceptionHandler = { _, exception in
            self.loadError = exception?.toString() ?? "JavaScript 执行异常"
        }
        context.evaluateScript(script)
        self.context = context
        self.bridge = bridge
        return loadError == nil
    }

    func snapshot(completion: @escaping ([DeviceBattery], String?) -> Void) {
        ensureThread()
        enqueue { [self] in
            guard loadIfNeeded() else {
                DispatchQueue.main.async { completion([], self.loadError) }
                return
            }
            loadError = nil
            guard let function = context?.objectForKeyedSubscript("snapshot"), !function.isUndefined else {
                DispatchQueue.main.async { completion([], "插件缺少 snapshot()") }
                return
            }
            let value = function.call(withArguments: [])
            if let error = loadError {
                DispatchQueue.main.async { completion([], error) }
                return
            }
            let payload = value?.toDictionary() as? [String: Any] ?? [:]
            let rows = payload["devices"] as? [[String: Any]] ?? []
            let devices = rows.map { self.device(from: $0) }
            let scriptStatus = payload["status"] as? String
            let bridgeStatus = bridge?.status() ?? ""
            let status = [scriptStatus, bridgeStatus].compactMap { value -> String? in
                guard let value = value, !value.isEmpty else { return nil }
                return "\(manifest.name)：\(value)"
            }.joined(separator: "；")
            DispatchQueue.main.async { completion(devices, status.isEmpty ? nil : status) }
        }
    }

    func selfTest(completion: @escaping ([String]) -> Void) {
        ensureThread()
        enqueue { [self] in
            guard loadIfNeeded() else {
                DispatchQueue.main.async { completion([self.loadError ?? "插件加载失败"]) }
                return
            }
            loadError = nil
            guard let function = context?.objectForKeyedSubscript("selfTest"), !function.isUndefined else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let result = function.call(withArguments: [])
            let errors = result?.toArray() as? [String] ?? []
            let allErrors = errors + (loadError.map { [$0] } ?? [])
            DispatchQueue.main.async { completion(allErrors) }
        }
    }

    private func device(from row: [String: Any]) -> DeviceBattery {
        let name = row["name"] as? String ?? manifest.name
        let kind = (row["kind"] as? String).flatMap(DeviceKind.init(rawValue:)) ?? DeviceKind.infer(from: name)
        let transportValue = row["transport"] as? String ?? "hid"
        let transport = Transport(rawValue: transportValue) ?? {
            switch transportValue {
            case "logitechReceiver": return .logitechReceiver
            case "bluetooth": return .bluetooth
            case "ble": return .ble
            case "usb": return .usb
            default: return .hid
            }
        }()
        let rawLevel = (row["level"] as? NSNumber)?.intValue
        let level = rawLevel.flatMap { (0...100).contains($0) ? $0 : nil }
        let timestamp = (row["lastUpdate"] as? NSNumber)?.doubleValue
        let extra = (row["extra"] as? [String: Any])?.reduce(into: [String: String]()) { result, item in
            result[item.key] = String(describing: item.value)
        } ?? [:]
        var enrichedExtra = extra
        enrichedExtra["插件"] = "\(manifest.name) v\(manifest.version)"
        let policy = (row["sourcePolicy"] as? String) ?? manifest.sourcePolicy
        return DeviceBattery(
            id: "plugin-\(manifest.id)-\(row["id"] as? String ?? name)",
            name: name,
            kind: kind,
            transport: transport,
            level: level,
            charging: row["charging"] as? Bool ?? false,
            connected: row["connected"] as? Bool ?? true,
            source: .devicePlugin,
            detail: row["detail"] as? String,
            lastUpdate: timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
            stale: row["stale"] as? Bool ?? false,
            extra: enrichedExtra,
            pluginID: manifest.id,
            sourcePolicy: policy
        )
    }
}

@MainActor
final class PluginManager {
    private(set) var descriptors: [PluginDescriptor] = []
    private var instances: [String: PluginInstance] = [:]

    func reload() {
        let directory = PluginInstaller.pluginsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var descriptors: [PluginDescriptor] = []
        var instances: [String: PluginInstance] = [:]
        for url in urls where url.pathExtension == "pmplugin" {
            do {
                let manifest = try PluginInstaller.manifest(at: url)
                descriptors.append(PluginDescriptor(
                    id: manifest.id,
                    name: manifest.name,
                    version: manifest.version,
                    path: url.path,
                    status: "已加载"
                ))
                instances[manifest.id] = self.instances[manifest.id] ?? PluginInstance(manifest: manifest, bundle: url)
            } catch {
                let id = url.deletingPathExtension().lastPathComponent
                descriptors.append(PluginDescriptor(
                    id: id,
                    name: id,
                    version: "—",
                    path: url.path,
                    status: error.localizedDescription
                ))
            }
        }
        self.descriptors = descriptors.sorted { $0.name < $1.name }
        self.instances = instances
    }

    func install(from url: URL) throws {
        _ = try PluginInstaller.install(from: url)
        reload()
    }

    func snapshotAll(completion: @escaping ([DeviceBattery], [String]) -> Void) {
        let plugins = Array(instances.values)
        guard !plugins.isEmpty else {
            DispatchQueue.main.async { completion([], []) }
            return
        }
        var remaining = plugins.count
        var allDevices: [DeviceBattery] = []
        var statuses: [String] = []
        var finished = false

        let finishOne: ([DeviceBattery], String?) -> Void = { devices, status in
            guard !finished else { return }
            allDevices.append(contentsOf: devices)
            if let status = status { statuses.append(status) }
            remaining -= 1
            if remaining == 0 {
                finished = true
                completion(allDevices, statuses)
            }
        }
        for plugin in plugins { plugin.snapshot(completion: finishOne) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard !finished else { return }
            finished = true
            statuses.append("插件读取超时，已跳过本次结果")
            completion(allDevices, statuses)
        }
    }

    func selfTestAll(completion: @escaping ([String]) -> Void) {
        let plugins = Array(instances.values)
        guard !plugins.isEmpty else {
            completion(["未安装任何插件；请设置 POWERMETER_PLUGIN_DIR 或先安装插件"])
            return
        }
        var remaining = plugins.count
        var errors: [String] = []
        for plugin in plugins {
            plugin.selfTest { result in
                errors.append(contentsOf: result.map { "\(plugin.manifest.name)：\($0)" })
                remaining -= 1
                if remaining == 0 { completion(errors) }
            }
        }
    }
}

@MainActor
enum PluginSelfTestMode {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let manager = PluginManager()
        manager.reload()
        print("PowerMeter \(AppVersion.text) · 插件 API v\(powerMeterPluginAPIVersion)")
        print("插件目录：\(PluginInstaller.pluginsDirectory().path)")
        for descriptor in manager.descriptors {
            print("· \(descriptor.name) v\(descriptor.version) [\(descriptor.status)]")
        }
        manager.selfTestAll { errors in
            if errors.isEmpty {
                print("全部插件自测通过")
                exit(0)
            }
            for error in errors { print("失败：\(error)") }
            exit(1)
        }
    }
}
