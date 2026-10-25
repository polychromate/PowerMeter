import AppKit

MainActor.assumeIsolated {
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
