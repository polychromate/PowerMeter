import SwiftUI
import WidgetKit

struct PowerMeterProvider: TimelineProvider {
    func placeholder(in context: Context) -> PowerMeterEntry {
        PowerMeterEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (PowerMeterEntry) -> Void) {
        WidgetStore.heartbeat()
        completion(PowerMeterEntry(date: Date(), snapshot: WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PowerMeterEntry>) -> Void) {
        WidgetStore.heartbeat()
        let entry = PowerMeterEntry(date: Date(), snapshot: WidgetStore.load())
        // 主程序每分钟刷新一次数据，这里紧随其后；系统会自行节流
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(90))))
    }
}

struct PowerMeterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PowerMeterBattery", provider: PowerMeterProvider()) { entry in
            PowerMeterWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("设备电量")
        .description("在桌面上显示键盘、鼠标、耳机的电量。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])    }
}

@main
struct PowerMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        PowerMeterWidget()
    }
}
