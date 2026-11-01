import AppKit
import SwiftUI
import Combine

// MARK: - 尺寸档位

enum TileSizeMode: String, CaseIterable {
    case small, regular, large

    var title: String {
        switch self {
        case .small: return "小"
        case .regular: return "中"
        case .large: return "大"
        }
    }

    var metrics: TileMetrics { TileMetrics.of(self) }
}

/// 磁贴的度量参数。视图与窗口高度计算共用一份，避免两处各写一套导致错位。
struct TileMetrics {
    let width: CGFloat
    let rowHeight: CGFloat
    let maxRows: Int
    let iconFont: CGFloat
    let iconWidth: CGFloat
    let nameFont: CGFloat
    let levelFont: CGFloat
    let bigLevelFont: CGFloat
    let barWidth: CGFloat

    static func of(_ mode: TileSizeMode) -> TileMetrics {
        switch mode {
        case .small:
            return TileMetrics(width: 176, rowHeight: 24, maxRows: 3, iconFont: 9.5, iconWidth: 15,
                               nameFont: 10.5, levelFont: 10.5, bigLevelFont: 27, barWidth: 26)
        case .regular:
            return TileMetrics(width: 212, rowHeight: 27, maxRows: 4, iconFont: 10.5, iconWidth: 17,
                               nameFont: 11.5, levelFont: 11.5, bigLevelFont: 32, barWidth: 32)
        case .large:
            return TileMetrics(width: 252, rowHeight: 31, maxRows: 5, iconFont: 12, iconWidth: 19,
                               nameFont: 12.5, levelFont: 12.5, bigLevelFont: 38, barWidth: 38)
        }
    }
}

// MARK: - 外观

enum TileTheme: String, CaseIterable {
    case glass, light, dark

    var title: String {
        switch self {
        case .glass: return "毛玻璃"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 毛玻璃用深色 HUD 材质，文字固定浅色；浅色主题才换成深色文字
    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .glass, .dark: return .dark
        }
    }
}

enum TileLevelMode: String, CaseIterable {
    case desktop, floating

    var title: String {
        switch self {
        case .desktop: return "贴在桌面"
        case .floating: return "始终置顶"
        }
    }

    var hint: String {
        switch self {
        case .desktop: return "磁贴位于桌面图标之上、普通窗口之下，回到桌面就能看到"
        case .floating: return "磁贴浮在所有窗口之上，适合边工作边盯电量"
        }
    }
}

// MARK: - 偏好

/// 磁贴的所有可调项，直接落在 UserDefaults；变化时由控制器刷新窗口。
/// 只在主线程读写，因此不加 actor 隔离，免得 SwiftUI 里每次取单例都要跨隔离域。
final class TilePreferences: ObservableObject {
    static let shared = TilePreferences()

    private let defaults = UserDefaults.standard

    @Published var visible: Bool {
        didSet { defaults.set(visible, forKey: Keys.visible) }
    }
    @Published var theme: TileTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var size: TileSizeMode {
        didSet { defaults.set(size.rawValue, forKey: Keys.size) }
    }
    @Published var level: TileLevelMode {
        didSet { defaults.set(level.rawValue, forKey: Keys.level) }
    }
    @Published var locked: Bool {
        didSet { defaults.set(locked, forKey: Keys.locked) }
    }
    @Published var showFooter: Bool {
        didSet { defaults.set(showFooter, forKey: Keys.showFooter) }
    }

    private enum Keys {
        static let visible = "tile.visible"
        static let theme = "tile.theme"
        static let size = "tile.size"
        static let level = "tile.level"
        static let locked = "tile.locked"
        static let showFooter = "tile.showFooter"
    }

    private init() {
        let d = UserDefaults.standard
        // 0.5.0 起主推系统桌面小组件，自绘贴片改为可选，默认不出现
        if d.object(forKey: Keys.visible) == nil { d.set(false, forKey: Keys.visible) }
        visible = d.bool(forKey: Keys.visible)
        theme = TileTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .glass
        size = TileSizeMode(rawValue: d.string(forKey: Keys.size) ?? "") ?? .regular
        level = TileLevelMode(rawValue: d.string(forKey: Keys.level) ?? "") ?? .desktop
        locked = d.bool(forKey: Keys.locked)
        showFooter = d.object(forKey: Keys.showFooter) == nil ? true : d.bool(forKey: Keys.showFooter)
    }
}

extension Notification.Name {
    /// 「把磁贴移回默认位置」：设置面板发出，控制器执行
    static let powerMeterResetTilePosition = Notification.Name("PowerMeterResetTilePosition")
}

// MARK: - 窗口

/// 无边框、不抢焦点的浮层。默认落在桌面层级，点它不会切走当前 App。
final class TileWindow: NSPanel {
    var onDoubleClick: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && event.clickCount == 2 {
            onDoubleClick?()
        }
        super.sendEvent(event)
    }
}

// MARK: - 控制器

@MainActor
final class DesktopTileController: NSObject, NSWindowDelegate, NSMenuDelegate {
    private let store: DeviceStore
    private let prefs: TilePreferences
    private var window: TileWindow?
    private var hostingView: NSHostingView<TileRootView>?
    private var cancellables = Set<AnyCancellable>()
    private var snapWorkItem: DispatchWorkItem?
    private var isAdjustingFrame = false

    /// 双击磁贴 → 打开菜单栏面板
    var onOpenPanel: (() -> Void)?

    private let edgeInset: CGFloat = 16

    init(store: DeviceStore, prefs: TilePreferences = .shared) {
        self.store = store
        self.prefs = prefs
        super.init()

        NotificationCenter.default.addObserver(
            forName: .powerMeterResetTilePosition, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.moveToDefaultPosition() }
        }

        observeChanges()
        if prefs.visible { show() }
    }

    // MARK: 生命周期

    private func observeChanges() {
        store.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.syncContentSize()
            }
            .store(in: &cancellables)

        // 所有偏好都是 @Published，统一在下一轮主循环里应用
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async { self.applyPreferences() }
            }
            .store(in: &cancellables)
    }

    private func applyPreferences() {
        guard let window = window else {
            if prefs.visible { show() }
            return
        }
        if prefs.visible {
            applyWindowStyle()
            syncContentSize()
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        applyWindowStyle()
        syncContentSize()
        window.orderFrontRegardless()
    }

    private func makeWindow() -> TileWindow {
        let metrics = prefs.size.metrics
        let window = TileWindow(
            contentRect: NSRect(x: 0, y: 0, width: metrics.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = !prefs.locked
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.delegate = self
        window.onDoubleClick = { [weak self] in
            Task { @MainActor in self?.onOpenPanel?() }
        }

        let host = NSHostingView(rootView: TileRootView(store: store, prefs: prefs))
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        host.menu = buildMenu()
        host.menu?.delegate = self
        window.contentView = host
        hostingView = host

        let height = Self.contentHeight(deviceCount: store.devices.count,
                                        metrics: metrics,
                                        showFooter: prefs.showFooter)
        window.setFrame(restoreFrame(width: metrics.width, height: height)
                        ?? defaultFrame(width: metrics.width, height: height),
                        display: false)
        return window
    }

    private func applyWindowStyle() {
        guard let window = window else { return }
        window.level = prefs.level == .desktop ? Self.desktopLevel : .floating
        window.isMovableByWindowBackground = !prefs.locked
    }

    /// 桌面图标层之上、普通窗口之下
    private static var desktopLevel: NSWindow.Level {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        return NSWindow.Level(rawValue: iconLevel + 1)
    }

    // MARK: 尺寸

    /// 高度按视图结构算出来，和 SwiftUI 里用的行高、间距保持一致。
    /// 比让 SwiftUI 自己报尺寸更可控：窗口不会因为一次布局抖动闪一下。
    static func contentHeight(deviceCount: Int, metrics: TileMetrics, showFooter: Bool) -> CGFloat {
        let verticalPadding: CGFloat = 18
        let footer = showFooter ? 5 + ceil((metrics.nameFont - 2.5) * 1.35) : 0

        if deviceCount == 0 {
            return verticalPadding + metrics.rowHeight + footer
        }
        if deviceCount == 1 {
            let title = ceil(metrics.nameFont * 1.34)
            let number = ceil(metrics.bigLevelFont * 1.22)
            let subtitle = ceil((metrics.nameFont - 1.5) * 1.32)
            return verticalPadding + title + 4 + number + 4 + subtitle + 2 + footer
        }
        let rows = min(deviceCount, metrics.maxRows)
        let rowsHeight = CGFloat(rows) * metrics.rowHeight + CGFloat(rows - 1)
        let overflow = deviceCount > metrics.maxRows ? ceil((metrics.nameFont - 2) * 1.4) + 2 : 0
        return verticalPadding + rowsHeight + overflow + footer
    }

    private func syncContentSize() {
        guard let window = window, prefs.visible else { return }
        let metrics = prefs.size.metrics
        let height = Self.contentHeight(deviceCount: store.devices.count,
                                        metrics: metrics,
                                        showFooter: prefs.showFooter)
        var frame = window.frame
        guard abs(frame.width - metrics.width) > 0.5 || abs(frame.height - height) > 0.5 else { return }
        isAdjustingFrame = true
        frame.size = NSSize(width: metrics.width, height: height)
        // 保持顶边不动，设备变多时向下生长
        frame.origin.y = window.frame.maxY - height
        window.setFrame(frame, display: true)
        isAdjustingFrame = false
    }

    // MARK: 位置

    private func defaultFrame(width: CGFloat, height: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - width - 28,
                      y: visible.maxY - height - 28,
                      width: width, height: height)
    }

    private var screenKey: String { "tile.screen" }
    private var relXKey: String { "tile.relX" }
    private var relYKey: String { "tile.relY" }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame else { return }
        savePosition()
        scheduleSnap()
    }

    private func savePosition() {
        guard let window = window, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.frame
        let frame = window.frame
        guard area.width > 1, area.height > 1 else { return }
        let defaults = UserDefaults.standard
        defaults.set(screen.localizedName, forKey: screenKey)
        defaults.set(Double((frame.minX - area.minX) / area.width), forKey: relXKey)
        // 用顶边做基准，窗口高度变化时不会整体往上跑
        defaults.set(Double((frame.maxY - area.minY) / area.height), forKey: relYKey)
    }

    private func restoreFrame(width: CGFloat, height: CGFloat) -> NSRect? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: relXKey) != nil,
              defaults.object(forKey: relYKey) != nil else { return nil }
        let name = defaults.string(forKey: screenKey) ?? ""
        let screen = NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.main
        guard let area = screen?.frame else { return nil }
        let origin = NSPoint(x: area.minX + CGFloat(defaults.double(forKey: relXKey)) * area.width,
                             y: area.minY + CGFloat(defaults.double(forKey: relYKey)) * area.height - height)
        return clamp(NSRect(origin: origin, size: NSSize(width: width, height: height)), to: screen)
    }

    /// 屏幕拔插或分辨率变化后，保证磁贴还有一部分留在屏幕内
    private func clamp(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        guard let area = (screen ?? NSScreen.main)?.frame else { return frame }
        var result = frame
        let margin: CGFloat = 24
        result.origin.x = min(max(result.origin.x, area.minX - result.width + margin), area.maxX - margin)
        result.origin.y = min(max(result.origin.y, area.minY - result.height + margin), area.maxY - margin)
        return result
    }

    func moveToDefaultPosition() {
        guard let window = window else { return }
        isAdjustingFrame = true
        window.setFrame(defaultFrame(width: window.frame.width, height: window.frame.height), display: true)
        isAdjustingFrame = false
        UserDefaults.standard.removeObject(forKey: relXKey)
        UserDefaults.standard.removeObject(forKey: relYKey)
    }

    /// 拖动结束后靠近屏幕边缘就吸附，避免磁贴半截悬空
    private func scheduleSnap() {
        snapWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.snapToEdges() }
        }
        snapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func snapToEdges() {
        guard let window = window, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        var frame = window.frame
        let threshold: CGFloat = 20
        var changed = false

        if abs(frame.minX - area.minX) < threshold {
            frame.origin.x = area.minX + edgeInset; changed = true
        } else if abs(area.maxX - frame.maxX) < threshold {
            frame.origin.x = area.maxX - frame.width - edgeInset; changed = true
        }
        if abs(frame.maxY - area.maxY) < threshold {
            frame.origin.y = area.maxY - frame.height - edgeInset; changed = true
        } else if abs(frame.minY - area.minY) < threshold {
            frame.origin.y = area.minY + edgeInset; changed = true
        }
        guard changed else { return }
        isAdjustingFrame = true
        window.setFrame(frame, display: true, animate: true)
        isAdjustingFrame = false
        savePosition()
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in makeMenuItems() { menu.addItem(item) }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in makeMenuItems() { menu.addItem(item) }
        return menu
    }

    private func makeMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.append(submenu(title: "尺寸",
                             options: TileSizeMode.allCases.map { ($0.title, $0.rawValue, prefs.size == $0) },
                             action: #selector(setSize(_:))))
        items.append(submenu(title: "外观",
                             options: TileTheme.allCases.map { ($0.title, $0.rawValue, prefs.theme == $0) },
                             action: #selector(setTheme(_:))))
        items.append(submenu(title: "层级",
                             options: TileLevelMode.allCases.map { ($0.title, $0.rawValue, prefs.level == $0) },
                             action: #selector(setLevel(_:))))
        items.append(.separator())
        items.append(checkItem("锁定位置", on: prefs.locked, action: #selector(toggleLock)))
        items.append(checkItem("显示更新时间", on: prefs.showFooter, action: #selector(toggleFooter)))
        items.append(.separator())
        items.append(actionItem("移回默认位置", action: #selector(resetPosition)))
        items.append(actionItem("打开电量面板", action: #selector(openPanel)))
        items.append(actionItem("隐藏磁贴", action: #selector(hideTile)))
        items.append(.separator())
        items.append(actionItem("退出 PowerMeter", action: #selector(quitApp)))
        return items
    }

    private func submenu(title: String, options: [(String, String, Bool)], action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (name, raw, selected) in options {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = raw
            item.state = selected ? .on : .off
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }

    private func checkItem(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = TileSizeMode(rawValue: raw) else { return }
        prefs.size = value
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = TileTheme(rawValue: raw) else { return }
        prefs.theme = value
    }

    @objc private func setLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = TileLevelMode(rawValue: raw) else { return }
        prefs.level = value
    }

    @objc private func toggleLock() { prefs.locked.toggle() }
    @objc private func toggleFooter() { prefs.showFooter.toggle() }
    @objc private func resetPosition() { moveToDefaultPosition() }
    @objc private func openPanel() { onOpenPanel?() }
    @objc private func hideTile() { prefs.visible = false }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - 磁贴视图

struct TileRootView: View {
    @ObservedObject var store: DeviceStore
    @ObservedObject var prefs: TilePreferences
    /// 离屏渲染时覆盖外观：毛玻璃是 NSVisualEffectView，ImageRenderer 画不出来
    var overrideTheme: TileTheme?
    var overrideSize: TileSizeMode?

    private var metrics: TileMetrics { (overrideSize ?? prefs.size).metrics }
    private var theme: TileTheme { overrideTheme ?? prefs.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.devices.isEmpty {
                emptyState
            } else if store.devices.count == 1, let device = store.devices.first {
                singleDevice(device)
            } else {
                deviceList
            }
            if prefs.showFooter { footer }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: metrics.width, alignment: .leading)
        .background(TileBackground(theme: theme))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(theme == .light ? 0 : 0.12), lineWidth: 0.5)
        )
        .environment(\.colorScheme, theme.colorScheme)
    }

    // MARK: 空状态

    private var emptyState: some View {
        HStack(spacing: 7) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: metrics.iconFont))
            Text(store.isRefreshing ? "正在扫描设备…" : "未发现已连接设备")
                .font(.system(size: metrics.nameFont))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .frame(height: metrics.rowHeight)
    }

    // MARK: 单设备

    private func singleDevice(_ device: DeviceBattery) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: device.kind.symbolName)
                    .font(.system(size: metrics.iconFont, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(device.displayName)
                    .font(.system(size: metrics.nameFont, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if device.isCritical {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: metrics.iconFont - 1))
                        .foregroundStyle(DeviceRow.criticalTint)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(device.level.map(String.init) ?? "—")
                    .font(.system(size: metrics.bigLevelFont, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(levelStyle(device))
                if device.level != nil {
                    Text("%")
                        .font(.system(size: metrics.nameFont + 1, weight: .medium))
                        .foregroundStyle(levelStyle(device).opacity(0.75))
                }
                Spacer(minLength: 0)
                if device.charging { chargingBadge }
            }

            Text(singleSubtitle(device))
                .font(.system(size: metrics.nameFont - 1.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.bottom, 2)
    }

    private func singleSubtitle(_ device: DeviceBattery) -> String {
        var parts: [String] = []
        if let tag = device.chemistry.tag { parts.append(tag) }
        parts.append(device.transport.short)
        if device.level == nil { parts.append("未上报电量") } else if device.stale { parts.append("上次读数") }
        return parts.joined(separator: " · ")
    }

    private var chargingBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 7, weight: .bold))
            Text("充电")
                .font(.system(size: metrics.nameFont - 2.5, weight: .semibold))
        }
        .foregroundStyle(DeviceRow.chargingTint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule(style: .continuous).fill(DeviceRow.chargingTint.opacity(0.16)))
    }

    // MARK: 多设备

    private var deviceList: some View {
        VStack(spacing: 1) {
            ForEach(store.devices.prefix(metrics.maxRows)) { device in
                deviceRow(device)
            }
            if store.devices.count > metrics.maxRows {
                Text("另有 \(store.devices.count - metrics.maxRows) 台设备")
                    .font(.system(size: metrics.nameFont - 2))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func deviceRow(_ device: DeviceBattery) -> some View {
        HStack(spacing: 6) {
            Image(systemName: device.kind.symbolName)
                .font(.system(size: metrics.iconFont, weight: .regular))
                .foregroundStyle(device.isCritical ? DeviceRow.criticalTint : .secondary)
                .frame(width: metrics.iconWidth, alignment: .leading)

            Text(device.displayName)
                .font(.system(size: metrics.nameFont, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            if device.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DeviceRow.chargingTint)
                    .fixedSize()
            }

            Spacer(minLength: 3)

            // 电量数字优先保留完整，长设备名自己去省略
            Text(device.levelText)
                .font(.system(size: metrics.levelFont, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                .foregroundStyle(levelStyle(device))

            miniBar(device)
        }
        .frame(height: metrics.rowHeight)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(device.isCritical ? DeviceRow.criticalTint.opacity(0.14) : Color.clear)
        )
    }

    private func miniBar(_ device: DeviceBattery) -> some View {
        let width = metrics.barWidth
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.13))
            if let level = device.level {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(levelStyle(device))
                    .frame(width: max(2, CGFloat(level) / 100 * width))
                    .opacity(device.stale ? 0.45 : 1)
            }
        }
        .frame(width: width, height: 4)
    }

    // MARK: 公共

    private var footer: some View {
        HStack(spacing: 4) {
            Text(footerText)
                .font(.system(size: metrics.nameFont - 2.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .frame(width: 9, height: 9)
            }
        }
        .padding(.top, 5)
    }

    private var footerText: String {
        guard let date = store.lastRefresh else { return "尚未刷新" }
        let seconds = Int(Date().timeIntervalSince(date))
        let time = seconds < 60 ? "\(max(seconds, 1)) 秒前" : "\(seconds / 60) 分钟前"
        return "\(store.devices.count) 台设备 · \(time)更新"
    }

    private func levelStyle(_ device: DeviceBattery) -> Color {
        guard device.level != nil else { return Color.secondary }
        return device.batteryColor.tint
    }
}

// MARK: - 背景

struct TileBackground: View {
    let theme: TileTheme

    @ViewBuilder
    var body: some View {
        switch theme {
        case .glass:
            // 模糊之上再压一层深色底：即使系统模糊在某些壁纸或层级下失效，文字也可读
            ZStack {
                TileGlassBackground()
                Color.black.opacity(0.38)
            }
        case .light:
            Color(red: 0.97, green: 0.97, blue: 0.98)
        case .dark:
            Color(red: 0.12, green: 0.12, blue: 0.13)
        }
    }
}

struct TileGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 设置面板

struct TileSettingsView: View {
    @ObservedObject var prefs: TilePreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            Divider()
            Toggle("显示桌面磁贴", isOn: $prefs.visible)
                .font(.system(size: 11.5))
            picker(title: "尺寸", selection: $prefs.size, options: TileSizeMode.allCases, label: { $0.title })
            picker(title: "外观", selection: $prefs.theme, options: TileTheme.allCases, label: { $0.title })
            picker(title: "层级", selection: $prefs.level, options: TileLevelMode.allCases, label: { $0.title })
            VStack(alignment: .leading, spacing: 6) {
                Toggle("锁定位置", isOn: $prefs.locked)
                Toggle("显示更新时间", isOn: $prefs.showFooter)
            }
            .font(.system(size: 11.5))
            Divider()
            Button("移回默认位置") {
                NotificationCenter.default.post(name: .powerMeterResetTilePosition, object: nil)
            }
            .font(.system(size: 10.5))
            Text("拖动磁贴可移动，靠近屏幕边缘会自动吸附；右键打开快捷菜单，双击回到这里。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("桌面显示")
                .font(.system(size: 13, weight: .semibold))
            Text("推荐用桌面小组件：在桌面空白处右键 →「编辑小组件」，搜索 PowerMeter 添加，可放小 / 中 / 大三种尺寸。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("下面这块是自绘贴片，不依赖系统小组件，位置和样式更自由，默认关闭。\(prefs.level.hint)。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func picker<Value: Hashable>(
        title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5))
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
