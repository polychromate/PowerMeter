import AppKit

MainActor.assumeIsolated {
    if let index = CommandLine.arguments.firstIndex(of: "--install-plugin") {
        guard index + 1 < CommandLine.arguments.count else {
            print("用法：PowerMeter --install-plugin <插件.pmplugin 或 zip>")
            exit(2)
        }
        do {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            let manifest = try PluginInstaller.install(from: url)
            print("已安装 \(manifest.name) v\(manifest.version)")
            exit(0)
        } catch {
            print("插件安装失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    if CommandLine.arguments.contains("--plugin-self-test") {
        PluginSelfTestMode.run()
        RunLoop.main.run()
        exit(0)
    }

    if CommandLine.arguments.contains("--dump") {
        DumpMode.run()
        exit(0)
    }

    if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
        let path = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "snapshot.png"
        SnapshotMode.run(path: path)
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
