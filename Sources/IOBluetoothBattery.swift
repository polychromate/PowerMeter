import Foundation
import IOBluetooth
import ObjectiveC.runtime

/// 通过 IOBluetooth 的私有电量属性读取经典蓝牙外设电量。
///
/// 为什么需要这条路：`system_profiler SPBluetoothDataType` 只对 AirPods 这类
/// Apple 设备给出 `device_batteryLevel*`，而 macOS「系统设置 → 蓝牙」里显示的
/// 第三方耳机电量（例如 HAYLOU S35 ANC 的 90%）来自 `IOBluetoothDevice` 的
/// 私有属性 `batteryPercentSingle` / `batteryPercentLeft` / `batteryPercentRight`
/// / `batteryPercentCase`，`system_profiler` 并不导出它们。
///
/// 这些属性由 bluetoothd 通过 HFP 的 `AT+IPHONEACCEV` 或厂商通道收到后写入，
/// 读取门槛较低（只需要蓝牙权限），是第三方 App 能拿到耳机电量的唯一可行通道。
enum IOBluetoothBatteryScanner {

    /// 已经确认会上报电量的设备（address）。用于区分「真 0%」和「不支持」
    private static var knownReporting: Set<String> = []
    private static let lock = NSLock()

    private typealias ByteGetter = @convention(c) (AnyObject, Selector) -> UInt8
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool

    private static func byte(_ object: AnyObject, _ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let imp = object.method(for: selector) else { return nil }
        return Int(unsafeBitCast(imp, to: ByteGetter.self)(object, selector))
    }

    private static func bool(_ object: AnyObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let imp = object.method(for: selector) else { return nil }
        return unsafeBitCast(imp, to: BoolGetter.self)(object, selector)
    }

    /// 是否具备调用条件。
    ///
    /// IOBluetooth 首次访问会连 bluetoothd，如果进程不是 LaunchServices 启动的
    /// （比如在终端里直接执行二进制），TCC 无法归属到 App，内核会直接中止进程。
    /// 因此命令行模式下必须跳过这个数据源。
    static var isAvailable: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_eproc.e_ppid == 1
    }

    static func scan() -> ([DeviceBattery], String?) {
        guard isAvailable else {
            return ([], "（命令行进程无法访问蓝牙权限，请在 App 界面中查看）")
        }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return ([], nil)
        }

        var devices: [DeviceBattery] = []
        for device in paired {
            guard device.isConnected() else { continue }
            let name = device.name ?? "未知蓝牙设备"
            let address = device.addressString ?? name

            let single = byte(device, "batteryPercentSingle") ?? 0
            let combined = byte(device, "batteryPercentCombined") ?? 0
            let left = byte(device, "batteryPercentLeft") ?? 0
            let right = byte(device, "batteryPercentRight") ?? 0
            let caseLevel = byte(device, "batteryPercentCase") ?? 0
            let multi = bool(device, "isMultiBatteryDevice") ?? false
            let overUSB = bool(device, "isConnectedOverUSB") ?? false

            var level: Int?
            if single > 0 {
                level = single
            } else if combined > 0 {
                level = combined
            } else if multi, left > 0 || right > 0 {
                level = min(left, right)
            }

            if level == nil {
                // 全为 0：要么电量真的耗尽，要么这台设备根本不上报
                lock.lock()
                let known = knownReporting.contains(address)
                lock.unlock()
                if known {
                    // 上报过的设备偶发读到全 0（HFP 毛刺 / 瞬时掉线），
                    // 不置 0 以免误触低电量告警；返回 nil 由上层沿用缓存读数并标 stale。
                    // 真实耗尽的设备几分钟后缓存过期，会回到「电量未知」。
                    level = nil
                } else {
                    continue
                }
            } else if let value = level, value > 0 {
                lock.lock()
                knownReporting.insert(address)
                lock.unlock()
            }

            // TWS 耳机把左右耳和充电盒分开上报，附带展示出来
            var extras: [String: String] = [:]
            if multi {
                if left > 0 { extras["左耳"] = "\(left)%" }
                if right > 0 { extras["右耳"] = "\(right)%" }
                if caseLevel > 0 { extras["充电盒"] = "\(caseLevel)%" }
            }
            if !address.isEmpty { extras["地址"] = address }

            let transport: Transport = overUSB ? .usb : .bluetooth
            let detail = multi ? "蓝牙上报（双耳独立电量）" : "蓝牙上报"

            devices.append(DeviceBattery(
                id: "iobt-\(address)",
                name: name,
                kind: DeviceKind.infer(from: name),
                transport: transport,
                level: level,
                charging: false,
                connected: true,
                source: .ioBluetooth,
                detail: detail,
                lastUpdate: Date(),
                extra: extras
            ))
        }
        return (devices, nil)
    }
}
