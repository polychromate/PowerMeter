import SwiftUI
import WidgetKit

/// 环形电量：外圈进度 + 中心设备图标
struct LevelRing: View {
    let device: WidgetDevice
    var size: CGFloat = 52
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle()
                .stroke(device.tint.opacity(0.20), lineWidth: lineWidth)
            if let level = device.level {
                Circle()
                    .trim(from: 0, to: max(0.03, CGFloat(level) / 100))
                    .stroke(device.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(device.stale ? 0.45 : 1)
            }
            Image(systemName: device.symbolName)
                .font(.system(size: size * 0.30, weight: .regular))
                .foregroundStyle(device.tint)
        }
        .frame(width: size, height: size)
    }
}

struct WidgetEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("未发现设备")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 方形：一台主设备，环形 + 大数字
struct SingleDeviceView: View {
    let snapshot: WidgetSnapshot
    var ringSize: CGFloat = 46
    var numberSize: CGFloat = 34
    var showsUpdate = true

    var body: some View {
        if let device = snapshot.primaryDevice {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: device.symbolName)
                        .font(.system(size: 9.5, weight: .medium))
                    Text(device.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if device.charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(device.tint)
                    }
                }
                .foregroundStyle(.secondary)

                Spacer(minLength: 3)

                HStack(alignment: .center, spacing: 9) {
                    LevelRing(device: device, size: ringSize, lineWidth: max(4, ringSize * 0.11))
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(device.level.map(String.init) ?? "—")
                            .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if device.level != nil {
                            Text("%")
                                .font(.system(size: numberSize * 0.38, weight: .medium))
                                .opacity(0.7)
                        }
                    }
                    .foregroundStyle(device.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                }

                Spacer(minLength: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if showsUpdate, let footer = footerText {
                        Text(footer)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            WidgetEmptyView()
        }
    }

    private var footerText: String? { snapshot.deviceFooter }
}

/// 长方形但只有一台设备时：横向铺开，避免整块下面空着
struct WideSingleDeviceView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if let device = snapshot.primaryDevice {
            HStack(alignment: .center, spacing: 16) {
                LevelRing(device: device, size: 74, lineWidth: 7)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: device.symbolName)
                            .font(.system(size: 10, weight: .medium))
                        Text(device.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if device.charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(device.tint)
                        }
                    }
                    .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(device.level.map(String.init) ?? "—")
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if device.level != nil {
                            Text("%")
                                .font(.system(size: 14, weight: .medium))
                                .opacity(0.7)
                        }
                    }
                    .foregroundStyle(device.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                    Text(device.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let footer = snapshot.deviceFooter {
                        Text(footer)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            WidgetEmptyView()
        }
    }
}

/// 长方形 / 大方块：设备列表
struct DeviceListView: View {
    let snapshot: WidgetSnapshot
    let limit: Int

    private var shown: [WidgetDevice] { Array(snapshot.devices.prefix(limit)) }

    var body: some View {
        if shown.isEmpty {
            WidgetEmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "battery.100")
                        .font(.system(size: 9, weight: .medium))
                    Text("设备电量")
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer(minLength: 0)
                    if let date = snapshot.updatedDate {
                        Text(shortRelative(date))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)

                VStack(spacing: 6) {
                    ForEach(shown) { device in
                        row(device)
                    }
                }

                if snapshot.devices.count > limit {
                    Text("另有 \(snapshot.devices.count - limit) 台")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ device: WidgetDevice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: device.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(device.tint)
                .frame(width: 14, alignment: .leading)
            Text(device.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if device.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(device.tint)
            }
            Spacer(minLength: 3)
            Text(device.levelText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(device.tint)
                .fixedSize()
        }
    }

    private func shortRelative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        return seconds < 60 ? "\(max(seconds, 1))秒前" : "\(seconds / 60)分钟前"
    }
}

struct PowerMeterWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PowerMeterEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SingleDeviceView(snapshot: entry.snapshot, ringSize: 46, numberSize: 31)
        case .systemMedium:
            if entry.snapshot.devices.count <= 1 {
                WideSingleDeviceView(snapshot: entry.snapshot)
            } else {
                DeviceListView(snapshot: entry.snapshot, limit: 3)
            }
        case .systemLarge:
            DeviceListView(snapshot: entry.snapshot, limit: 7)
        default:
            SingleDeviceView(snapshot: entry.snapshot)
        }
    }
}
