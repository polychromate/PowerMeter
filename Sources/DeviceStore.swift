import Foundation
import SwiftUI

/// 聚合内置数据源与外部插件，产出统一的设备列表。
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var notes: [String] = []
    @Published private(set) var plugins: [PluginDescriptor] = []

    private let pluginManager = PluginManager()
    private var refreshTimer: Timer?
    private var lastBLEScan: Date?

    // 各数据源的最近一次结果
    private var bluetoothDevices: [DeviceBattery] = []
    private var hidDevices: [DeviceBattery] = []
    private var ioBluetoothDevices: [DeviceBattery] = []
    private var pluginDevices: [DeviceBattery] = []

    // 上次有效电量缓存：设备休眠或暂时读不到时沿用，避免界面跳动
    private var cache: [String: (level: Int, charging: Bool, date: Date)] = [:]

    private var pendingTasks = 0
    private var finishedTasks = 0
    private var bluetoothStatus: String?

    private let bleEnabled: Bool

    init(enableBLE: Bool = true) {
        bleEnabled = enableBLE
        pluginManager.reload()
        plugins = pluginManager.descriptors
        guard enableBLE else { return }
        BLEScanner.shared.onUpdate = { [weak self] in
            self?.rebuild()
        }
        BLEScanner.shared.start()
    }

    /// 离屏渲染用：直接注入一份设备列表（数据来自最近一次真实扫描）
    func applyPreview(_ list: [DeviceBattery]) {
        devices = list.map { device in
            var copy = device
            let verdict = BatteryClassifier.classify(copy)
            copy.chemistry = verdict.chemistry
            copy.chemistryReason = verdict.reason
            return copy
        }.sorted { $0.sortKey < $1.sortKey }
        lastRefresh = Date()
    }

    func startAutoRefresh(interval: TimeInterval = 60) {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func reloadPlugins() {
        pluginManager.reload()
        plugins = pluginManager.descriptors
        refresh()
    }

    func installPlugin(from url: URL) throws {
        try pluginManager.install(from: url)
        plugins = pluginManager.descriptors
        refresh()
    }

    func openPluginDirectory() {
        let directory = PluginInstaller.pluginsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        pendingTasks = 0
        finishedTasks = 0
        notes = []

        // 1. 通用 HID 系统属性与标准电量元素（同步，毫秒级）
        hidDevices = HIDBatteryScanner.scan()
        rebuild()

        // 2. 系统蓝牙
        pendingTasks += 1
        BluetoothBatteryScanner.scan { [weak self] devices, error in
            guard let self = self else { return }
            Task { @MainActor in
                self.bluetoothDevices = devices
                if let error = error { self.notes.append(error) }
                self.finishTask()
            }
        }

        // 3. 系统已接收的蓝牙私有电量属性
        // IOBluetooth 的 pairedDevices() 内部会等主队列信号量，必须在后台线程调用
        pendingTasks += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let result = IOBluetoothBatteryScanner.scan()
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.ioBluetoothDevices = result.0
                if let error = result.1 { self.notes.append(error) }
                self.finishTask()
            }
        }

        // 4. 独立安装的设备插件
        pendingTasks += 1
        pluginManager.snapshotAll { [weak self] devices, statuses in
            Task { @MainActor in
                guard let self = self else { return }
                self.pluginDevices = devices
                self.notes.append(contentsOf: statuses)
                self.finishTask()
            }
        }

        // 5. BLE 电池服务（每 5 分钟扫一次，避免耗电和干扰连接）
        if bleEnabled, lastBLEScan == nil || Date().timeIntervalSince(lastBLEScan!) > 300 {
            lastBLEScan = Date()
            BLEScanner.shared.scanOnce()
        }
    }

    private func finishTask() {
        finishedTasks += 1
        rebuild()
        if finishedTasks >= pendingTasks {
            isRefreshing = false
            lastRefresh = Date()
        }
    }

    private func rebuild() {
        var all = hidDevices + bluetoothDevices + ioBluetoothDevices + pluginDevices
        if bleEnabled {
            all += BLEScanner.shared.snapshot()
            if let status = BLEScanner.shared.statusText {
                bluetoothStatus = status
            }
        }
        all = merge(all)
        devices = all.sorted { $0.sortKey < $1.sortKey }

        var bannerSet = notes
        if let status = bluetoothStatus, !all.contains(where: { $0.transport == .bluetooth || $0.transport == .ble }) {
            bannerSet.append(status)
        }
        notes = Array(NSOrderedSet(array: bannerSet)) as? [String] ?? bannerSet
        writeRuntimeSnapshot(devices)
    }

    private func sourceRank(_ device: DeviceBattery) -> Int {
        if device.source == .devicePlugin {
            return device.sourcePolicy == "fallback" ? 5 : 0
        }
        switch device.source {
        case .logitechHIDPP: return 0
        case .ioBluetooth: return 1
        case .systemProfiler: return 2
        case .hidProperty: return 3
        case .hidReport, .bleGATT: return 4
        case .vendorHID: return 5
        case .devicePlugin: return 5
        case .none: return 6
        }
    }

    /// 同一设备可能出现在多个数据源。默认系统电量优先、通用直读兜底；
    /// 声明 preferPlugin / pluginOnly 的设备插件优先于系统结果。
    private func merge(_ input: [DeviceBattery]) -> [DeviceBattery] {
        var groups: [String: [DeviceBattery]] = [:]
        for device in input {
            groups[normalize(device.name), default: []].append(device)
        }

        var merged: [DeviceBattery] = []
        for (_, group) in groups {
            let sorted = group.sorted { a, b in
                let aHas = a.level != nil ? 0 : 1
                let bHas = b.level != nil ? 0 : 1
                if aHas != bHas { return aHas < bHas }
                let rank = sourceRank(a) - sourceRank(b)
                if rank != 0 { return rank < 0 }
                return a.lastUpdate > b.lastUpdate
            }
            var best = sorted[0]
            if best.level == nil, let fallback = sorted.first(where: { $0.level != nil }) {
                best.level = fallback.level
                best.source = fallback.source
                best.pluginID = fallback.pluginID
                best.sourcePolicy = fallback.sourcePolicy
                if best.detail == nil || best.detail!.contains("未") {
                    best.detail = fallback.detail
                }
            }

            let extraDetails = sorted.compactMap { $0.detail }.filter { !$0.isEmpty && $0 != best.detail }
            if best.level == nil, let hint = extraDetails.first(where: { $0.contains("未") }) {
                best.detail = hint
            }
            best.connected = group.contains { $0.connected }
            if !best.charging { best.charging = group.contains { $0.charging } }
            for device in group where device.id != best.id {
                for (key, value) in device.extra where best.extra[key] == nil {
                    best.extra[key] = value
                }
            }

            let cacheKey = normalize(best.name)
            if let level = best.level {
                cache[cacheKey] = (level, best.charging, Date())
                best.stale = false
            } else if let cached = cache[cacheKey], Date().timeIntervalSince(cached.date) < 900 {
                best.level = cached.level
                best.charging = cached.charging
                best.stale = true
            }

            let verdict = BatteryClassifier.classify(best)
            best.chemistry = verdict.chemistry
            best.chemistryReason = verdict.reason
            merged.append(best)
        }
        // 接收器插着 / 蓝牙已配对不等于设备在线
        return merged.filter { $0.connected }
    }

    private func normalize(_ name: String) -> String {
        var text = name.lowercased()
        for noise in [" wireless", " multi-device", " multi device", " triathlon",
                      "inphic ", "xinmeng ", "新盟"] {
            text = text.replacingOccurrences(of: noise, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func writeRuntimeSnapshot(_ devices: [DeviceBattery]) {
        let rows: [[String: Any]] = devices.map { device in
            [
                "name": device.name,
                "level": device.level as Any,
                "charging": device.charging,
                "chemistry": device.chemistry.rawValue,
                "chemistryReason": device.chemistryReason,
                "transport": device.transport.rawValue,
                "source": device.source.rawValue,
                "pluginID": device.pluginID as Any,
                "detail": device.detail ?? "",
                "stale": device.stale
            ]
        }
        let payload: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "notes": notes,
            "plugins": plugins.map { ["id": $0.id, "version": $0.version, "status": $0.status] },
            "menuBar": [
                "device": devices.menuBarCandidate?.name ?? "",
                "level": devices.menuBarCandidate?.level as Any,
                "chemistry": devices.menuBarCandidate?.chemistry.rawValue ?? "",
                "charging": devices.menuBarCandidate?.charging ?? false,
                "critical": devices.contains { $0.isCritical }
            ],
            "devices": rows
        ]
        DispatchQueue.global(qos: .utility).async {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let dir = base.appendingPathComponent("PowerMeter", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("last-scan.json"))
            }
        }
    }

    // MARK: - 菜单栏展示

    var menuBarDevice: DeviceBattery? {
        devices.menuBarCandidate
    }

    var criticalDevices: [DeviceBattery] {
        devices.filter { $0.isCritical }
    }

    var hasCriticalLithium: Bool {
        !criticalDevices.isEmpty
    }

    var criticalMessage: String? {
        guard let device = criticalDevices.min(by: { ($0.level ?? 0) < ($1.level ?? 0) }) else { return nil }
        let suffix = criticalDevices.count > 1 ? " 等 \(criticalDevices.count) 台设备" : ""
        return "\(device.displayName)\(suffix) 电量 \(device.levelText)，请及时充电"
    }

    var summaryLine: String {
        let known = devices.filter { $0.level != nil }
        if devices.isEmpty { return "未发现设备" }
        if known.isEmpty { return "\(devices.count) 台设备 · 电量未知" }
        let total = known.reduce(0) { $0 + ($1.level ?? 0) }
        let average = total / max(known.count, 1)
        var parts = ["\(devices.count) 台设备", "平均 \(average)%"]
        let charging = devices.filter { $0.charging }.count
        if charging > 0 { parts.append("\(charging) 台充电中") }
        return parts.joined(separator: " · ")
    }
}
