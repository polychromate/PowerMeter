import SwiftUI
import AppKit

/// 离屏渲染真实界面，用于检查 UI（`PowerMeter --snapshot out.png`）
enum SnapshotMode {
    @MainActor
    static func run(path: String) {
        let store = DeviceStore(enableBLE: false)

        // 命令行启动时蓝牙私有接口会直接中止进程，
        // 因此优先使用正常运行中的 App 写下的真实扫描结果来渲染。
        if let captured = SnapshotData.load() {
            store.applyPreview(captured)
        } else {
            store.refresh()
            let deadline = Date().addingTimeInterval(6)
            var lastCount = -1
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if !store.isRefreshing && !store.devices.isEmpty && store.devices.count == lastCount { break }
                lastCount = store.devices.count
            }
        }

        let view = ContentView(store: store, useMaterialBackground: false, scrollable: false)
            .frame(width: 380)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("已写出 \(path)  (\(Int(image.size.width))×\(Int(image.size.height)))")
        } catch {
            print("写入失败：\(error)")
        }
    }
}

/// 读取 App 运行时写下的 last-scan.json（真实抓取结果），用于离屏渲染
enum SnapshotData {
    private struct Payload: Decodable {
        struct Row: Decodable {
            let name: String
            let level: Int?
            let charging: Bool?
            let chemistry: String?
            let chemistryReason: String?
            let transport: String
            let source: String
            let detail: String?
            let stale: Bool?
        }
        let devices: [Row]
    }

    static func load() -> [DeviceBattery]? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appendingPathComponent("PowerMeter/last-scan.json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.devices.isEmpty else { return nil }

        return payload.devices.map { row in
            DeviceBattery(
                id: "preview-\(row.name)",
                name: row.name,
                kind: DeviceKind.infer(from: row.name),
                transport: Transport(rawValue: row.transport) ?? .bluetooth,
                level: row.level,
                charging: row.charging ?? false,
                connected: true,
                source: BatterySource(rawValue: row.source) ?? .none,
                detail: row.detail,
                lastUpdate: Date(),
                stale: row.stale ?? false,
                chemistry: BatteryChemistry(rawValue: row.chemistry ?? "") ?? .unknown,
                chemistryReason: row.chemistryReason ?? ""
            )
        }
    }
}
