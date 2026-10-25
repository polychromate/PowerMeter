import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DeviceStore
    /// 离屏渲染时不能用 NSVisualEffectView，改用纯色背景
    var useMaterialBackground = true
    /// 离屏渲染时 ScrollView 内容不会绘制，用普通堆栈代替
    var scrollable = true
    @State private var showAbout = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !store.notes.isEmpty {
                Divider()
                notesView
            }
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

    // MARK: - 提示区

    private var notesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.notes, id: \.self) { note in
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text(lastUpdateText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("关于") { showAbout.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .popover(isPresented: $showAbout, arrowEdge: .bottom) {
                    AboutView()
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
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
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
        case .bleGATT: return "BLE 电池服务"
        case .ioBluetooth: return "蓝牙上报"
        case .none: return "该设备未向系统提供电量"
        }
    }

    private var tooltip: String {
        var lines = [device.name]
        for (key, value) in device.extra.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)：\(value)")
        }
        lines.append("来源：\(device.source.rawValue) · \(device.transport.rawValue)")
        if device.stale { lines.append("当前未读到最新值，显示最近一次读数") }
        if device.level == nil { lines.append("设备未上报电量；如需查看请使用厂商 App") }
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

    private var symbolName: String {
        switch device.kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .headset: return "headphones"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gamepad: return "gamecontroller"
        case .speaker: return "hifispeaker"
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PowerMeter")
                .font(.system(size: 13, weight: .semibold))
            Text("Mac 外设电量监视器")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
            Text("数据来源")
                .font(.system(size: 11, weight: .medium))
            Text("· 罗技 HID++（接收器 / 蓝牙直连）\n· 系统蓝牙上报（AirPods 等）\n· HID 属性 BatteryPercent\n· BLE 电池服务 0x180F")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Divider()
            Text("设备不上报电量时，本工具无法凭空读取，\n界面会明确标注「电量未知」。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
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
