import Foundation
import CoreBluetooth
import IOBluetooth

enum TransportMode { case auto, ble, rfcomm }

func parseTransportMode(_ text: String) -> TransportMode? {
    switch text.lowercased() {
    case "auto": return .auto
    case "ble": return .ble
    case "rfcomm", "serial", "rfcomm10": return .rfcomm
    default: return nil
    }
}

let controlServiceUUID = CBUUID(string: "e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1")
let controlWriteUUID = CBUUID(string: "e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1")
let controlNotifyUUID = CBUUID(string: "e49a28e1-f69a-11e8-8eb2-f2801f1b9fd1")
let batteryServiceUUID = CBUUID(string: "180F")
let batteryLevelUUID = CBUUID(string: "2A19")

func makeTransport(mode: TransportMode, driver: Driver) -> TransportChannel? {
    let resolved: TransportMode
    if mode == .auto {
        if RfcommChannel.availablePublished(channel: 10) != nil { resolved = .rfcomm } else { resolved = .ble }
    } else { resolved = mode }
    switch resolved {
    case .rfcomm:
        if let channelID = RfcommChannel.availablePublished(channel: 10) {
            return RfcommChannel(driver: driver, channelID: channelID)
        }
        driver.printLine("no RFCOMM control channel published; is the Mic Pro connected to macOS as an audio device?")
        return nil
    case .ble:
        guard DeviceConfig.target != nil else {
            driver.printLine("no configured device; run: micproctl configure --address <BD_ADDR> --suffix <6 chars from the device name>")
            return nil
        }
        return BleChannel(driver: driver)
    case .auto: return nil
    }
}

/// Classic-Bluetooth RFCOMM channel 10 control transport. Requires the mic
/// to be connected to macOS as an audio device (mirrors upstream
/// `primaryControlAvailable`).
final class RfcommChannel: NSObject, TransportChannel, IOBluetoothRFCOMMChannelDelegate {
    let name = "bluetooth-rfcomm-ch10"
    private weak var driver: Driver?
    private let channelID: BluetoothRFCOMMChannelID
    private var channel: IOBluetoothRFCOMMChannel?
    private var streamBuffer = FrameStream()
    private var openFailedTimer: Timer?
    var onOpen: (() -> Void)?
    var onFrames: ((Frame) -> Void)?
    var onFail: ((String) -> Void)?
    init(driver: Driver, channelID: BluetoothRFCOMMChannelID) {
        self.driver = driver
        self.channelID = channelID
        super.init()
    }
    static func availablePublished(channel wanted: BluetoothRFCOMMChannelID) -> BluetoothRFCOMMChannelID? {
        guard let device = SystemBattery.device(), device.isConnected(),
              let services = device.services as? [IOBluetoothSDPServiceRecord] else { return nil }
        for record in services {
            var channel: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channel) == 0, channel == wanted { return channel }
        }
        return nil
    }
    func start() {
        guard let device = SystemBattery.device() else { onFail?("configured device not found among paired classic Bluetooth devices"); return }
        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        if status != 0 { onFail?(String(format: "RFCOMM open failed (%08X)", status)); return }
        channel = opened
        openFailedTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.channelAvailable { return }
            self.onFail?("opening RFCOMM channel timed out (is the device still connected as an audio device?)")
        }
    }
    private var channelAvailable = false
    private func actuallyOpened() {
        channelAvailable = true
        openFailedTimer?.invalidate()
        onOpen?()
    }
    func write(_ data: Data) {
        guard let channel = channel else { return }
        var bytes = [UInt8](data)
        let status = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        if status != 0 { printDebug(String(format: "rfcomm write status %08X", status)) }
    }
    func close() {
        openFailedTimer?.invalidate()
        channel?.setDelegate(nil)
        _ = channel?.close()
        channel = nil
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == 0 else { onFail?(String(format: "RFCOMM open completed with status %08X", status)); return }
        DispatchQueue.main.async { self.actuallyOpened() }
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { self.onFail?("RFCOMM channel closed before the operation completed") }
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        let bytes = Data(bytes: pointer, count: count)
        DispatchQueue.main.async {
            for frame in self.streamBuffer.append(bytes) { self.onFrames?(frame) }
        }
    }
}

/// CoreBluetooth control transport: connect to the configured device's
/// control service (write+notify FIFOs), same pairing-mode behavior as the
/// upstream app: known-peripheral first, then advertisement scan.
final class BleChannel: NSObject, TransportChannel, CBCentralManagerDelegate, CBPeripheralDelegate {
    let name = "ble"
    private weak var driver: Driver?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var receiver: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var streamBuffer = FrameStream()
    private var scanTimer: Timer?
    private var connectTimer: Timer?
    private var opening = false
    private var opened = false
    var onOpen: (() -> Void)?
    var onFrames: ((Frame) -> Void)?
    var onFail: ((String) -> Void)?
    init(driver: Driver) { self.driver = driver; super.init() }
    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }
    private func failOut(_ message: String) { if !opened { onFail?(message) } }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unsupported { failOut("no Bluetooth hardware on this Mac") }
            else if central.state == .unauthorized { failOut("Bluetooth permission denied; allow this tool in System Settings > Privacy & Security > Bluetooth") }
            else { failOut("Bluetooth is not on") }
            return
        }
        begin()
    }
    private func begin() {
        guard let central = central else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [controlServiceUUID])
        if let match = connected.first(where: { $0.name?.contains(DeviceConfig.serialSuffix) == true }) {
            connect(match); return
        }
        if let cached = UserDefaults.standard.string(forKey: "micproctl.verifiedPeripheralID"),
           let uuid = UUID(uuidString: cached),
           let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first,
           peripheral.name?.contains(DeviceConfig.serialSuffix) == true {
            printDebug("using previously verified peripheral \(peripheral.identifier)")
            connect(peripheral); return
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.central?.stopScan()
            self?.failOut("no BLE advertisement from a device named …\(DeviceConfig.serialSuffix) within 30 s; triple-press the Mic Pro power button to enter pairing mode and retry, or connect it as an audio device and use --transport rfcomm")
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.contains(DeviceConfig.serialSuffix) else { return }
        scanTimer?.invalidate()
        central.stopScan()
        connect(peripheral)
    }
    private func connect(_ peripheral: CBPeripheral) {
        guard !opening, self.peripheral == nil else { return }
        guard SystemBattery.device() != nil else { failOut("device configuration does not match any paired classic Bluetooth device; run: micproctl doctor"); return }
        opening = true
        self.peripheral = peripheral
        peripheral.delegate = self
        printDebug("connecting BLE \(peripheral.identifier)")
        connectTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.failOut("BLE connect timeout; triple-press the power button to re-enter pairing mode")
        }
        central?.connect(peripheral, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimer?.invalidate()
        peripheral.discoverServices([controlServiceUUID, batteryServiceUUID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimer?.invalidate()
        failOut("BLE connect failed: \(error.map { String(describing: $0) } ?? "unknown")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if opened { onFail?("BLE control link disconnected before the operation completed") }
        else { failOut("BLE link lost during connect: \(error.map { String(describing: $0) } ?? "none")") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { failOut("service discovery failed: \(error.localizedDescription)"); return }
        var foundControl = false, foundBattery = false
        for service in peripheral.services ?? [] {
            if service.uuid == controlServiceUUID {
                foundControl = true
                peripheral.discoverCharacteristics([controlWriteUUID, controlNotifyUUID], for: service)
            }
            if service.uuid == batteryServiceUUID {
                foundBattery = true
                peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
            }
        }
        if !foundControl { failOut("control service missing on this device") }
        _ = foundBattery
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { failOut("characteristic discovery failed: \(error.localizedDescription)"); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == batteryLevelUUID {
                batteryCharacteristic = characteristic
                if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
                if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
            }
            if characteristic.uuid == controlWriteUUID { writer = characteristic }
            if characteristic.uuid == controlNotifyUUID { receiver = characteristic }
        }
        guard let writer = writer, let receiver = receiver,
              receiver.properties.contains(.notify),
              writer.properties.contains(.write) || writer.properties.contains(.writeWithoutResponse) else { return }
        peripheral.setNotifyValue(true, for: receiver)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == controlNotifyUUID else { return }
        connectTimer?.invalidate()
        if let error = error { failOut("notify subscription failed: \(error.localizedDescription)"); return }
        guard characteristic.isNotifying else { failOut("device refused notify subscription"); return }
        guard !opened else { return }
        opened = true
        onOpen?()
    }
    func write(_ data: Data) {
        guard let peripheral = peripheral, let writer = writer else { return }
        peripheral.writeValue(data, for: writer, type: writer.properties.contains(.write) ? .withResponse : .withoutResponse)
    }
    func close() {
        scanTimer?.invalidate(); connectTimer?.invalidate()
        if let peripheral = peripheral { central?.cancelPeripheralConnection(peripheral) }
        central = nil
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { printDebug("notify error: \(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == batteryLevelUUID {
            if value.count == 1, let level = value.first, level <= 100 { driver?.context.batteryCharacteristicLevel = Int(level) }
            return
        }
        for frame in streamBuffer.append(value) { onFrames?(frame) }
    }
}
