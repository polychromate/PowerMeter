import Foundation
import CoreBluetooth

/// BLE 电池服务（GATT Battery Service 0x180F / 0x2A19）扫描。
/// 对支持 BLE 电量上报的耳机、鼠标等有效；设备不广播该服务时读不到。
final class BLEScanner: NSObject {
    static let shared = BLEScanner()

    private var central: CBCentralManager?
    private var pending: [UUID: CBPeripheral] = [:]
    private var readings: [UUID: (name: String, level: Int, date: Date)] = [:]
    private var isScanning = false
    private var timer: Timer?

    /// 状态说明，供 UI 展示（未授权 / 蓝牙关闭等）
    private(set) var statusText: String?
    var onUpdate: (() -> Void)?

    private let batteryService = CBUUID(string: "180F")
    private let batteryCharacteristic = CBUUID(string: "2A19")

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// 触发一次短扫描
    func scanOnce(duration: TimeInterval = 5) {
        start()
        guard let central = central, central.state == .poweredOn, !isScanning else { return }
        isScanning = true
        central.scanForPeripherals(withServices: [batteryService], options: nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    private func stopScan() {
        timer?.invalidate()
        timer = nil
        guard isScanning else { return }
        isScanning = false
        central?.stopScan()
    }

    func snapshot() -> [DeviceBattery] {
        readings.map { uuid, reading in
            DeviceBattery(
                id: "ble-\(uuid.uuidString)",
                name: reading.name,
                kind: DeviceKind.infer(from: reading.name),
                transport: .ble,
                level: reading.level,
                connected: true,
                source: .bleGATT,
                detail: "BLE 电池服务",
                lastUpdate: reading.date
            )
        }
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusText = nil
            scanOnce()
        case .poweredOff:
            statusText = "蓝牙已关闭"
        case .unauthorized:
            statusText = "未授予蓝牙权限（系统设置 › 隐私与安全性 › 蓝牙）"
        case .unsupported:
            statusText = "此 Mac 不支持蓝牙"
        default:
            statusText = nil
        }
        onUpdate?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard pending[peripheral.identifier] == nil else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard !name.isEmpty else { return }
        pending[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pending.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        pending.removeValue(forKey: peripheral.identifier)
    }
}

extension BLEScanner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == batteryService }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([batteryCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == batteryCharacteristic }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer { central?.cancelPeripheralConnection(peripheral) }
        guard characteristic.uuid == batteryCharacteristic,
              let value = characteristic.value?.first,
              value <= 100 else { return }
        let name = peripheral.name ?? pending[peripheral.identifier]?.name ?? "BLE 设备"
        readings[peripheral.identifier] = (name, Int(value), Date())
        onUpdate?()
    }
}
