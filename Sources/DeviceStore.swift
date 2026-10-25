import Foundation
import SwiftUI

/// 聚合所有数据源，产出统一的设备列表。
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var notes: [String] = []

    private let logitech = LogitechProvider()
    private var refreshTimer: Timer?
    private var lastBLEScan: Date?

    // 各数据源的最近一次结果
    private var logitechDevices: [DeviceBattery] = []
    private var bluetoothDevices: [DeviceBattery] = []
    private var hidDevices: [DeviceBattery] = []
    private var ioBluetoothDevices: [DeviceBattery] = []

    // 上次有效电量缓存：devices 睡眠或暂时读不到时沿用，避免界面跳动
    private var cache: [String: (level: Int, charging: Bool, date: Date)] = [:]

    private var pendingTasks = 0
    private var finishedTasks = 0
    private var bluetoothStatus: String?

    private let bleEnabled: Bool

    init(enableBLE: Bool = true) {
        bleEnabled = enableBLE
        guard enableBLE else { return }
        BLEScanner.shared.onUpdate = { [weak self] in
            self?.rebuild()
        }
        BLEScanner.shared.start()
    }

    /// 离屏渲染用：直接注入一份设备列表（数据来自最近一次真实扫描）
    func applyPreview(_ list: [DeviceBattery]) {
        devices = list.sorted { $0.sortKey < $1.sortKey }
        lastRefresh = Date()
    }

    func startAutoRefresh(interval: TimeInterval = 60) {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        pendingTasks = 0
        finishedTasks = 0
        notes = []

        // 1. 通用 HID 属性（同步，毫秒级）
        hidDevices = HIDBatteryScanner.scan()
        rebuild()

        // 2. 罗技 HID++
        pendingTasks += 1
        logitech.snapshot { [weak self] devices, fatal in
            guard let self = self else { return }
            Task { @MainActor in
                self.logitechDevices = devices
                if let fatal = fatal { self.notes.append(fatal) }
                self.finishTask()
            }
        }

        // 3. 系统蓝牙
        pendingTasks += 1
        BluetoothBatteryScanner.scan { [weak self] devices, error in
            guard let self = self else { return }
            Task { @MainActor in
                self.bluetoothDevices = devices
                if let error = error { self.notes.append(error) }
                self.finishTask()
            }
        }

        // 3.5 蓝牙私有电量属性（第三方耳机电量，等同系统设置里的显示）
        // 注意：IOBluetooth 的 pairedDevices() 内部会等主队列信号量，必须在后台线程调用
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

        // 4. BLE 电池服务（每 5 分钟扫一次，避免耗电）
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
        var all = logitechDevices + hidDevices + bluetoothDevices + ioBluetoothDevices
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

    /// 同一设备可能出现在多个数据源（如罗技键盘同时出现在系统蓝牙列表）。
    /// 按名称归一化合并，优先保留有读数、精度更高的来源。
    private func merge(_ input: [DeviceBattery]) -> [DeviceBattery] {
        var groups: [String: [DeviceBattery]] = [:]
        for device in input {
            groups[normalize(device.name), default: []].append(device)
        }

        let priority: [BatterySource: Int] = [
            .logitechHIDPP: 0,
            .hidProperty: 1,
            .bleGATT: 2,
            .ioBluetooth: 3,
            .systemProfiler: 4,
            .none: 5
        ]

        var merged: [DeviceBattery] = []
        for (_, group) in groups {
            let sorted = group.sorted { a, b in
                let aHas = a.level != nil ? 0 : 1
                let bHas = b.level != nil ? 0 : 1
                if aHas != bHas { return aHas < bHas }
                return (priority[a.source] ?? 9) < (priority[b.source] ?? 9)
            }
            var best = sorted[0]
            // 若最佳来源没有读数，借用同组其它来源的读数
            if best.level == nil, let fallback = sorted.first(where: { $0.level != nil }) {
                best.level = fallback.level
                best.source = fallback.source
                if best.detail == nil || best.detail!.contains("未") {
                    best.detail = fallback.detail
                }
            }
            // 补上其它来源的补充信息（例如蓝牙 RSSI、左右耳电量）
            let extraDetails = sorted.compactMap { $0.detail }.filter { !$0.isEmpty && $0 != best.detail }
            if best.level == nil, let hint = extraDetails.first(where: { $0.contains("未") }) {
                best.detail = hint
            }
            best.connected = group.contains { $0.connected }
            if !best.charging { best.charging = group.contains { $0.charging } }

            // 缓存机制
            if let level = best.level {
                cache[best.id] = (level, best.charging, Date())
                best.stale = false
            } else if let cached = cache[best.id], Date().timeIntervalSince(cached.date) < 900 {
                best.level = cached.level
                best.charging = cached.charging
                best.stale = true
            }

            merged.append(best)
        }
        return merged
    }

    private func normalize(_ name: String) -> String {
        var text = name.lowercased()
        for noise in [" wireless", " multi-device", " multi device", " triathlon"] {
            text = text.replacingOccurrences(of: noise, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 把最近一次扫描结果写到 Application Support，便于排查「为什么某设备没有电量」
    private func writeRuntimeSnapshot(_ devices: [DeviceBattery]) {
        let rows: [[String: Any]] = devices.map { device in
            [
                "name": device.name,
                "level": device.level as Any,
                "charging": device.charging,
                "transport": device.transport.rawValue,
                "source": device.source.rawValue,
                "detail": device.detail ?? "",
                "stale": device.stale
            ]
        }
        let payload: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
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

    var lowestLevel: Int? {
        devices.compactMap { $0.level }.min()
    }

    var hasCriticalDevice: Bool {
        devices.contains { ($0.level ?? 100) <= 15 && !$0.charging }
    }

    var summaryLine: String {
        let known = devices.filter { $0.level != nil }
        if devices.isEmpty { return "未发现设备" }
        if known.isEmpty { return "\(devices.count) 台设备 · 电量未知" }
        let total = known.reduce(0) { $0 + ($1.level ?? 0) }
        let average = total / max(known.count, 1)
        return "\(devices.count) 台设备 · 平均 \(average)%"
    }
}
