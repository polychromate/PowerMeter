import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = DeviceStore()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 只允许一个实例：罗技接收器是独占资源，多开会导致读不到电量
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.chenge.PowerMeter")
        if running.count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: "电量")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
        popover.contentSize = NSSize(width: 380, height: 260)

        // 设备数据变化 → 更新菜单栏
        store.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        store.$isRefreshing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        store.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizePopoverIfNeeded() }
            .store(in: &cancellables)

        updateStatusItem()
        store.startAutoRefresh(interval: 60)

        // 便于截图与调试：--preview 启动后自动展开面板
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.showPopover()
            }
        }
    }

    // MARK: - 菜单栏

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let lowest = store.lowestLevel

        let symbol: String
        if let lowest = lowest {
            switch lowest {
            case 90...: symbol = "battery.100"
            case 65...: symbol = "battery.75"
            case 40...: symbol = "battery.50"
            case 15...: symbol = "battery.25"
            default: symbol = "battery.0"
            }
        } else {
            symbol = "battery.100"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "设备电量")
        image?.isTemplate = true
        button.image = image

        if let lowest = lowest {
            button.title = " \(lowest)%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        } else {
            button.title = " —"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }

        button.contentTintColor = store.hasCriticalDevice ? .systemRed : nil
        button.toolTip = "PowerMeter · \(store.summaryLine)"
    }

    // MARK: - 弹窗

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        installEventMonitor()
    }

    /// 设备数量变化后重新计算面板高度
    private func resizePopoverIfNeeded() {
        guard popover.isShown, let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.height > 0 else { return }
        let height = min(max(fitting.height, 160), 460)
        if abs(popover.contentSize.height - height) > 2 {
            popover.contentSize = NSSize(width: 380, height: height)
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeEventMonitor()
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
