import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DeviceStore
    /// 离屏渲染时不能用 NSVisualEffectView，改用纯色背景
    var useMaterialBackground = true
    /// 离屏渲染时 ScrollView 内容不会绘制，用普通堆栈代替
    var scrollable = true
    @State private var showAbout = false
    @State private var showPlugins = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = store.criticalMessage {
                criticalBanner(message)
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .background(useMaterialBackground ? AnyView(VisualEffectBackground())
                                          : AnyView(Color(nsColor: .windowBackgroundColor)))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("设备电量")
                    .font(.system(size: 14, weight: .semibold))
                Text(store.summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            } else {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("立即刷新")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 正文

    /// 未充电的锂电池设备电量过低时的提醒条
    private func criticalBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DeviceRow.criticalTint)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeviceRow.criticalTint.opacity(0.10))
    }

    private var content: some View {
        Group {
            if store.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(store.isRefreshing ? "正在扫描设备…" : "未发现已连接的设备")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else if scrollable {
                ScrollView {
                    deviceList
                }
                .frame(maxHeight: 340)
            } else {
                deviceList
            }
        }
    }

    private var deviceList: some View {
        VStack(spacing: 2) {
            ForEach(store.devices) { device in
                DeviceRow(device: device)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text("v\(AppVersion.text) · \(lastUpdateText)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("插件") { showPlugins.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .popover(isPresented: $showPlugins, arrowEdge: .bottom) {
                    PluginsView(store: store)
                }
            Button("关于") { showAbout.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .popover(isPresented: $showAbout, arrowEdge: .bottom) {
                    AboutView(notes: store.notes)
                }
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var lastUpdateText: String {
        guard let date = store.lastRefresh else { return "尚未刷新" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 1)) 秒前更新" }
        return "\(seconds / 60) 分钟前更新"
    }
}

// MARK: - 单行

struct DeviceRow: View {
    let device: DeviceBattery

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(device.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(device.transport.short)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                HStack(spacing: 5) {
                    if device.chemistry.tag != nil {
                        ChemistryTag(chemistry: device.chemistry)
                    }
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(device.isCritical ? DeviceRow.criticalTint.opacity(0.10)
                                        : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var subtitle: String {
        if let detail = device.detail, !detail.isEmpty { return detail }
        switch device.source {
        case .logitechHIDPP: return "HID++ 直读"
        case .systemProfiler: return "系统蓝牙上报"
        case .hidProperty: return "HID 属性"
        case .hidReport: return "HID 标准电量直读"
        case .devicePlugin: return "独立设备插件"
        case .bleGATT: return "BLE 电池服务"
        case .ioBluetooth: return "蓝牙上报"
        case .vendorHID: return "厂商私有协议"
        case .none: return "该设备未向系统提供电量"
        }
    }

    private var tooltip: String {
        var lines = [device.name]
        if let tag = device.chemistry.tag {
            lines.append("电池类型：\(tag)（\(device.chemistryReason)）")
        } else if !device.chemistryReason.isEmpty {
            lines.append("电池类型：未知（\(device.chemistryReason)）")
        }
        for (key, value) in device.extra.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)：\(value)")
        }
        lines.append("来源：\(device.source.rawValue) · \(device.transport.rawValue)")
        if device.stale { lines.append("当前未读到最新值，显示最近一次读数") }
        if device.level == nil { lines.append("设备未上报电量；如需查看请使用厂商 App") }
        if device.isCritical {
            lines.append("⚠️ 电量低于 \(DeviceBattery.lowBatteryThreshold)%，请及时充电")
        }
        return lines.joined(separator: "\n")
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(width: 27, height: 27)
        .overlay(alignment: .bottomTrailing) {
            if device.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 6.5, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 12, height: 12)
                    .background(Circle().fill(DeviceRow.chargingTint))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                    .offset(x: 4, y: 4)
            }
        }
    }

    static let chargingTint = Color(red: 0.13, green: 0.55, blue: 0.95)
    static let criticalTint = Color(red: 0.87, green: 0.26, blue: 0.24)

    private var symbolName: String {
        switch device.kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .headset: return "headphones"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gamepad: return "gamecontroller"
        case .speaker: return "hifispeaker"
        case .microphone: return "mic.fill"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if device.charging {
                HStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("充电")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(DeviceRow.chargingTint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(DeviceRow.chargingTint.opacity(0.15))
                )
            }
            Text(device.levelText)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(device.level == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(device.batteryColor.tint))
                .frame(width: 34, alignment: .trailing)
            BatteryBar(level: device.level, style: device.batteryColor, stale: device.stale)
        }
    }
}

// MARK: - 电池类型标签

/// 「锂电池」/「换电池」小标签。锂电池用蓝色表示需要充电，可更换电池用棕色表示换节电池即可。
struct ChemistryTag: View {
    let chemistry: BatteryChemistry

    var body: some View {
        Text(chemistry.tag ?? "")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .fixedSize()
            .help(chemistry.summary)
    }

    private var tint: Color {
        switch chemistry {
        case .lithium: return Color(red: 0.16, green: 0.52, blue: 0.86)
        case .replaceable: return Color(red: 0.60, green: 0.45, blue: 0.22)
        case .unknown: return .secondary
        }
    }
}

// MARK: - 电量条

struct BatteryBar: View {
    let level: Int?
    let style: BatteryLevelStyle
    var stale = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.primary.opacity(0.09))
            if let level = level {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(style.tint)
                    .frame(width: max(3, CGFloat(level) / 100 * 46))
                    .opacity(stale ? 0.45 : 1)
            }
        }
        .frame(width: 46, height: 5)
        .overlay(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

extension BatteryLevelStyle {
    var tint: Color {
        switch self {
        case .healthy: return Color(red: 0.20, green: 0.66, blue: 0.36)
        case .low: return Color(red: 0.93, green: 0.60, blue: 0.13)
        case .critical: return Color(red: 0.87, green: 0.26, blue: 0.24)
        case .charging: return Color(red: 0.16, green: 0.53, blue: 0.92)
        case .unknown: return Color.secondary
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    /// 数据源运行状态提示（正常时为空）
    var notes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("PowerMeter")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("v\(AppVersion.text)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text("Mac 外设电量监视器")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
            Text("电池类型标签")
                .font(.system(size: 11, weight: .medium))
            Text("· 锂电池：内置可充电电池，电量低需要充电\n· 换电池：AA/AAA 电池，电量低换一节即可")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text("菜单栏优先显示未充电的锂电池设备；\n电量低于 \(DeviceBattery.lowBatteryThreshold)% 时变红提醒。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Divider()
            Text("数据来源")
                .font(.system(size: 11, weight: .medium))
            Text("· 系统蓝牙与 IOBluetooth 上报\n· HID BatteryPercent 系统属性\n· HID Battery Strength 标准直读\n· BLE 电池服务 0x180F\n· 独立设备插件（罗技、新盟等）")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Divider()
            Text("运行状态")
                .font(.system(size: 11, weight: .medium))
            if notes.isEmpty {
                Text("所有数据源工作正常")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text(note)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Divider()
            Text("设备不上报电量时，本工具无法凭空读取，\n界面会明确标注「电量未知」。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}

// MARK: - 插件管理

struct PluginsView: View {
    @ObservedObject var store: DeviceStore
    @State private var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            pluginList
            Divider()
            actions
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .alert("插件安装失败", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("好") { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("设备插件")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("API v\(powerMeterPluginAPIVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text("插件独立安装和升级，为新设备提供支持，无需更新主程序。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var pluginList: some View {
        if store.plugins.isEmpty {
            Text("尚未安装设备插件")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.plugins, id: \.id) { plugin in
                        PluginRowView(plugin: plugin)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private var actions: some View {
        HStack {
            Button("安装插件…", action: install)
            Button("重新载入") { store.reloadPlugins() }
            Spacer()
            Button("插件目录") { store.openPluginDirectory() }
        }
        .font(.system(size: 10.5))
    }

    private func install() {
        let panel = NSOpenPanel()
        panel.title = "选择 PowerMeter 插件"
        panel.message = "请选择 .pmplugin 插件包或其 zip 压缩包"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.installPlugin(from: url)
        } catch {
            installError = error.localizedDescription
        }
    }
}

struct PluginRowView: View {
    let plugin: PluginDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(plugin.name)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("v\(plugin.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(plugin.status)
                .font(.system(size: 9.5))
                .foregroundStyle(plugin.status == "已加载" ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 背景

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
