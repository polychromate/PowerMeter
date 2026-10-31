import Foundation
import IOKit
import IOKit.hid
import JavaScriptCore

@_silgen_name("IOHIDCheckAccess")
private func _IOHIDCheckAccess(_ requestType: UInt32) -> UInt32
@_silgen_name("IOHIDRequestAccess")
private func _IOHIDRequestAccess(_ requestType: UInt32) -> Bool

/// 插件可见的 HID 能力。每个方法都从 JavaScript 接收简单值，避免暴露原生对象。
@objc protocol PluginHIDJSExport: JSExport {
    func listDevices(_ match: [String: Any]) -> [[String: Any]]
    func openDevice(_ id: String) -> Bool
    func closeDevice(_ id: String)
    func setReport(_ request: [String: Any]) -> Bool
    func getReport(_ request: [String: Any]) -> [UInt8]
    func takeReports(_ id: String) -> [[UInt8]]
    func wait(_ milliseconds: Double)
    func status() -> String
    func requestAccess() -> String
}

private final class PluginHIDClient {
    let device: IOHIDDevice
    private var buffer = [UInt8](repeating: 0, count: 64)
    private(set) var reports: [[UInt8]] = []

    init?(device: IOHIDDevice) {
        self.device = device
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        IOHIDDeviceRegisterInputReportCallback(device, &buffer, buffer.count, { context, _, _, _, _, report, length in
            guard let context = context else { return }
            let client = Unmanaged<PluginHIDClient>.fromOpaque(context).takeUnretainedValue()
            client.reports.append((0..<length).map { report[$0] })
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    func drainReports() -> [[UInt8]] {
        defer { reports.removeAll() }
        return reports
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        close()
    }
}

/// 一个插件实例对应一个桥。所有方法都在该插件的线程和 RunLoop 上执行。
@objc final class PluginHIDBridge: NSObject, PluginHIDJSExport {
    private var candidates: [String: IOHIDDevice] = [:]
    private var clients: [String: PluginHIDClient] = [:]
    private var lastStatus = ""

    private func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func identifier(_ device: IOHIDDevice) -> String {
        let service = IOHIDDeviceGetService(device)
        var id: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &id) == kIOReturnSuccess {
            return "hid-\(id)"
        }
        let name = string(device, kIOHIDProductKey) ?? "device"
        let location = int(device, kIOHIDLocationIDKey) ?? 0
        return "hid-\(name)-\(location)"
    }

    private func requestPermission() -> String {
        let listenEvent: UInt32 = 1
        let status = _IOHIDCheckAccess(listenEvent)
        guard status != 0 else { return "" }
        _ = _IOHIDRequestAccess(listenEvent)
        switch _IOHIDCheckAccess(listenEvent) {
        case 0:
            return ""
        case 1:
            return "「输入监控」权限被拒绝。请到 系统设置 › 隐私与安全性 › 输入监控 启用 PowerMeter，然后重启 App"
        default:
            return "已请求「输入监控」权限，请在弹窗中允许（或到系统设置中启用），然后重启 App"
        }
    }

    func requestAccess() -> String {
        requestPermission()
    }

    func status() -> String {
        lastStatus
    }

    private func matches(_ device: IOHIDDevice, _ match: [String: Any]) -> Bool {
        let integerKeys = [
            "vendorID": kIOHIDVendorIDKey,
            "productID": kIOHIDProductIDKey,
            "usagePage": kIOHIDPrimaryUsagePageKey,
            "usage": kIOHIDPrimaryUsageKey
        ]
        for (key, property) in integerKeys {
            if let expected = (match[key] as? NSNumber)?.intValue,
               int(device, property) != expected {
                return false
            }
        }
        if let expected = match["transport"] as? String,
           string(device, kIOHIDTransportKey) != expected {
            return false
        }
        if let expected = (match["productContains"] as? String)?.lowercased(),
           !(string(device, kIOHIDProductKey) ?? "").lowercased().contains(expected) {
            return false
        }
        return true
    }

    private func descriptor(_ device: IOHIDDevice) -> [String: Any] {
        [
            "id": identifier(device),
            "product": string(device, kIOHIDProductKey) ?? "",
            "manufacturer": string(device, kIOHIDManufacturerKey) ?? "",
            "vendorID": int(device, kIOHIDVendorIDKey) ?? 0,
            "productID": int(device, kIOHIDProductIDKey) ?? 0,
            "usagePage": int(device, kIOHIDPrimaryUsagePageKey) ?? 0,
            "usage": int(device, kIOHIDPrimaryUsageKey) ?? 0,
            "transport": string(device, kIOHIDTransportKey) ?? "",
            "locationID": int(device, kIOHIDLocationIDKey) ?? 0
        ]
    }

    func listDevices(_ match: [String: Any]) -> [[String: Any]] {
        lastStatus = ""
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            if UInt32(bitPattern: rc) == 0xE00002E2 {
                lastStatus = requestPermission()
            } else {
                lastStatus = "IOHIDManagerOpen 失败：\(rc)"
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        var result: [[String: Any]] = []
        var discovered: [String: IOHIDDevice] = [:]
        for device in devices {
            let transport = string(device, kIOHIDTransportKey) ?? ""
            if transport == "SPMI" || transport == "SPU" || !matches(device, match) { continue }
            let id = identifier(device)
            discovered[id] = device
            result.append(descriptor(device))
        }
        candidates.merge(discovered) { _, new in new }
        return result.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }

    func openDevice(_ id: String) -> Bool {
        if clients[id] != nil { return true }
        guard let device = candidates[id] else {
            lastStatus = "HID 设备已断开或尚未枚举：\(id)"
            return false
        }
        guard let client = PluginHIDClient(device: device) else {
            lastStatus = requestPermission()
            if lastStatus.isEmpty { lastStatus = "无法打开 HID 设备：\(id)" }
            return false
        }
        clients[id] = client
        lastStatus = ""
        return true
    }

    func closeDevice(_ id: String) {
        clients[id]?.close()
        clients.removeValue(forKey: id)
    }

    private func reportType(_ value: Any?) -> IOHIDReportType? {
        switch value as? String {
        case "input": return kIOHIDReportTypeInput
        case "output": return kIOHIDReportTypeOutput
        case "feature": return kIOHIDReportTypeFeature
        default: return nil
        }
    }

    func setReport(_ request: [String: Any]) -> Bool {
        guard let id = request["id"] as? String,
              let client = clients[id],
              let type = reportType(request["type"]),
              let reportID = (request["reportID"] as? NSNumber)?.intValue else { return false }
        var data: [UInt8]
        if let values = request["data"] as? [UInt8] {
            data = values
        } else if let values = request["data"] as? [NSNumber] {
            data = values.map { $0.uint8Value }
        } else {
            return false
        }
        guard !data.isEmpty else { return false }
        let count = data.count
        let rc = data.withUnsafeMutableBytes { bytes -> IOReturn in
            IOHIDDeviceSetReport(client.device, type, CFIndex(reportID), bytes.baseAddress!, count)
        }
        if rc != kIOReturnSuccess { lastStatus = "SetReport 失败：\(rc)" }
        return rc == kIOReturnSuccess
    }

    func getReport(_ request: [String: Any]) -> [UInt8] {
        guard let id = request["id"] as? String,
              let client = clients[id],
              let type = reportType(request["type"]),
              let reportID = (request["reportID"] as? NSNumber)?.intValue else { return [] }
        let capacity = min(max((request["length"] as? NSNumber)?.intValue ?? 64, 1), 512)
        var data = [UInt8](repeating: 0, count: capacity)
        var length = CFIndex(capacity)
        let rc = IOHIDDeviceGetReport(client.device, type, CFIndex(reportID), &data, &length)
        guard rc == kIOReturnSuccess else {
            lastStatus = "GetReport 失败：\(rc)"
            return []
        }
        return Array(data.prefix(Int(length)))
    }

    func takeReports(_ id: String) -> [[UInt8]] {
        clients[id]?.drainReports() ?? []
    }

    func wait(_ milliseconds: Double) {
        let interval = min(max(milliseconds / 1000, 0.001), 1)
        CFRunLoopRunInMode(.defaultMode, interval, false)
    }

    func closeAll() {
        for client in clients.values { client.close() }
        clients.removeAll()
    }
}
