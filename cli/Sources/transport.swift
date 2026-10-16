import Foundation
import CoreBluetooth
import IOBluetooth

enum TransportMode { case auto, ble, rfcomm }

/// Failure phase so the driver can fall back before anything was sent.
enum TransportStage { case open, session }

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

/// Audio/headset profile UUIDs: their RFCOMM channels must never be mistaken
/// for the vendor settings serial, whatever channel number they got.
private let audioProfileUUIDs: Set<UInt16> = [0x1108, 0x110A, 0x110B, 0x1112, 0x111E, 0x111F]

struct ServiceRecordInfo { let channel: BluetoothRFCOMMChannelID; let name: String; let isAudioProfile: Bool }

/// All RFCOMM-carrying SDP records of the paired device, with service names.
func classicServiceRecords() -> [ServiceRecordInfo] {
    guard let device = SystemBattery.device(),
          let services = device.services as? [IOBluetoothSDPServiceRecord] else { return [] }
    var result: [ServiceRecordInfo] = []
    for record in services {
        var channel: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channel) == 0 else { continue }
        let isAudio = audioProfileUUIDs.contains { record.matchesUUID16($0) }
        result.append(ServiceRecordInfo(channel: channel, name: record.getServiceName() ?? "(unnamed)", isAudioProfile: isAudio))
    }
    return result.sorted { $0.channel < $1.channel }
}

func makeTransport(mode: TransportMode, channelOverride: BluetoothRFCOMMChannelID?, driver: Driver) -> TransportChannel? {
    let wanted = channelOverride ?? 10
    let resolved: TransportMode
    if mode == .auto {
        // Cached SDP records survive a dropped link; only pick the serial when
        // the classic Bluetooth link is actually up.
        let linkUp = SystemBattery.device()?.isConnected() == true
        resolved = (linkUp && RfcommChannel.selectSettingsChannel(preferred: wanted) != nil) ? .rfcomm : .ble
    } else { resolved = mode }
    switch resolved {
    case .rfcomm:
        if let channel = RfcommChannel.selectSettingsChannel(preferred: wanted) {
            return RfcommChannel(driver: driver, channelID: channel)
        }
        driver.printLine("no usable RFCOMM control channel published")
        driver.printLine("  run `micproctl doctor` to list the device's serial services and their channels")
        driver.printLine("  then retry with --rfcomm-channel N if the settings serial moved, or --transport ble")
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

/// Classic-Bluetooth RFCOMM control transport. Requires the mic to be
/// connected to macOS as an audio device (mirrors upstream
/// `primaryControlAvailable`).
final class RfcommChannel: NSObject, TransportChannel, IOBluetoothRFCOMMChannelDelegate {
    let name: String
    let channelID: BluetoothRFCOMMChannelID
    private weak var driver: Driver?
    private var channel: IOBluetoothRFCOMMChannel?
    private var streamBuffer = FrameStream()
    private var openFailedTimer: Timer?
    private var channelAvailable = false
    var onOpen: (() -> Void)?
    var onFrames: ((Frame) -> Void)?
    var onFail: ((String, TransportStage) -> Void)?
    var isOpen: Bool { channelAvailable }
    init(driver: Driver, channelID: BluetoothRFCOMMChannelID) {
        self.driver = driver
        self.channelID = channelID
        self.name = "bluetooth-rfcomm-ch\(channelID)"
        super.init()
    }
    /// Prefer a non-audio-profile record carrying the preferred channel number,
    /// then any record with that number, else none (mirrors upstream on 2.0.2.4
    /// where the settings serial publishes as channel 10).
    static func selectSettingsChannel(preferred: BluetoothRFCOMMChannelID) -> BluetoothRFCOMMChannelID? {
        let records = classicServiceRecords()
        guard !records.isEmpty else { return nil }
        if let match = records.first(where: { $0.channel == preferred && !$0.isAudioProfile }) { return match.channel }
        if let match = records.first(where: { $0.channel == preferred }) { return match.channel }
        return nil
    }
    func start() {
        guard let device = SystemBattery.device() else { onFail?("configured device not found among paired classic Bluetooth devices", .open); return }
        guard device.isConnected() else {
            onFail?("""
                the Mic Pro is not connected over Bluetooth right now — macOS drops the audio
                link whenever no app is capturing its input, and the TX also powers its radio
                down when idle. Power the mic on, then run `micproctl connect-audio` (or start
                any app that captures its input) and retry. Settings and battery also work via
                --transport ble without the audio link (triple-press power if discovery fails).
                """, .open)
            return
        }
        var opened: IOBluetoothRFCOMMChannel?
        printDebug(String(format: "rfcomm start: device=%@ connected=%d opening ch %d", device.name ?? "?", device.isConnected() ? 1 : 0, channelID))
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        printDebug(String(format: "rfcomm openAsync returned %08X, channel object: %@", status, opened == nil ? "nil" : "created"))
        if status != 0 { onFail?(String(format: "RFCOMM open failed (%08X) on channel %d", status, channelID), .open); return }
        channel = opened
        openFailedTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.channelAvailable { return }
            var services = "published services:"
            for record in classicServiceRecords() {
                services += "\n    channel \(record.channel): \(record.name)\(record.isAudioProfile ? "  [audio profile]" : "")"
            }
            self.onFail?("""
                RFCOMM channel \(self.channelID) never opened within 20 s — likely causes:
                  • the TX is already serving another control client — quit the vendor phone app
                    (or turn the phone's Bluetooth off) and close any other Mac tool using the mic
                  • this firmware may publish the settings serial on a different channel —
                    run `micproctl doctor` and retry with --rfcomm-channel N
                  • settings/battery also work over BLE: --transport ble
                \(services)
                """, .open)
        }
    }
    private func actuallyOpened() {
        printDebug("rfcomm channel actually opened; control traffic may begin")
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
        channelAvailable = false
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        printDebug(String(format: "rfcomm openComplete callback fired, status=%08X", status))
        guard status == 0 else { onFail?(String(format: "RFCOMM open completed with status %08X", status), .open); return }
        DispatchQueue.main.async { self.actuallyOpened() }
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async {
            if self.channelAvailable { self.onFail?("RFCOMM channel closed before the operation completed", .session) }
        }
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        let bytes = Data(bytes: pointer, count: count)
        DispatchQueue.main.async {
            for frame in self.streamBuffer.append(bytes) { self.onFrames?(frame) }
        }
    }
}

/// CoreBluetooth control transport: connects to the configured device's
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
    private var bootstrapTimer: Timer?
    private var opening = false
    private var opened = false
    /// CoreBluetooth work happens here so a wedged stack can never block the
    /// driver's run loop; every delegate callback hops back to main.
    private let bleQueue = DispatchQueue(label: "micproctl.ble")
    var onOpen: (() -> Void)?
    var onFrames: ((Frame) -> Void)?
    var onFail: ((String, TransportStage) -> Void)?
    var isOpen: Bool { opened }
    init(driver: Driver) { self.driver = driver; super.init() }
    private func onMain(_ body: @escaping () -> Void) { DispatchQueue.main.async(execute: body) }
    private func scheduleDeadline(_ seconds: TimeInterval, _ handler: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in handler() }
        RunLoop.main.add(timer, forMode: .default)
        return timer
    }
    func start() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            let manager = CBCentralManager(delegate: self, queue: self.bleQueue)
            self.onMain {
                self.central = manager
                // If the state callback never arrives (pending permission prompt,
                // or a headless context that cannot show one), say so.
                self.bootstrapTimer?.invalidate()
                self.bootstrapTimer = self.scheduleDeadline(20) { [weak self] in
                    guard let self = self, !self.opened else { return }
                    self.driver?.printLine("still waiting for the Bluetooth subsystem — if a permission prompt is visible, approve it; otherwise grant Bluetooth access to your terminal app in System Settings → Privacy & Security → Bluetooth (headless/SSH sessions cannot show the prompt).")
                }
            }
        }
    }
    private func failOut(_ message: String) {
        onFail?(message, opened ? .session : .open)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onMain {
            self.bootstrapTimer?.invalidate()
            guard central.state == .poweredOn else {
                if central.state == .unsupported { self.failOut("no Bluetooth hardware on this Mac") }
                else if central.state == .unauthorized { self.failOut("Bluetooth permission denied; allow this tool in System Settings > Privacy & Security > Bluetooth") }
                else { self.failOut("Bluetooth is not on") }
                return
            }
            self.begin()
        }
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
        scanTimer?.invalidate()
        scanTimer = scheduleDeadline(30) { [weak self] in
            self?.central?.stopScan()
            self?.failOut("""
                no BLE advertisement from a device named …\(DeviceConfig.serialSuffix) within 30 s —
                triple-press the Mic Pro power button to enter pairing mode and retry,
                or use --transport rfcomm while it is connected as an audio device
                """)
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.contains(DeviceConfig.serialSuffix) else { return }
        onMain {
            self.scanTimer?.invalidate()
            central.stopScan()
            self.connect(peripheral)
        }
    }
    private func connect(_ peripheral: CBPeripheral) {
        guard !opening, self.peripheral == nil else { return }
        guard SystemBattery.device() != nil else { failOut("device configuration does not match any paired classic Bluetooth device; run: micproctl doctor"); return }
        opening = true
        self.peripheral = peripheral
        peripheral.delegate = self
        printDebug("connecting BLE \(peripheral.identifier)")
        connectTimer?.invalidate()
        connectTimer = scheduleDeadline(20) { [weak self] in
            self?.failOut("BLE connect timeout; triple-press the power button to re-enter pairing mode")
        }
        central?.connect(peripheral, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onMain {
            self.connectTimer?.invalidate()
            peripheral.discoverServices([controlServiceUUID, batteryServiceUUID])
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onMain {
            self.connectTimer?.invalidate()
            self.failOut("BLE connect failed: \(error.map { String(describing: $0) } ?? "unknown")")
        }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onMain {
            if self.opened { self.onFail?("BLE control link disconnected before the operation completed", .session) }
            else { self.failOut("BLE link lost during connect: \(error.map { String(describing: $0) } ?? "none")") }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        onMain {
            if let error = error { self.failOut("service discovery failed: \(error.localizedDescription)"); return }
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
            if !foundControl { self.failOut("control service missing on this device") }
            _ = foundBattery
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        onMain {
            if let error = error { self.failOut("characteristic discovery failed: \(error.localizedDescription)"); return }
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == batteryLevelUUID {
                    self.batteryCharacteristic = characteristic
                    if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
                    if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
                }
                if characteristic.uuid == controlWriteUUID { self.writer = characteristic }
                if characteristic.uuid == controlNotifyUUID { self.receiver = characteristic }
            }
            guard let writer = self.writer, let receiver = self.receiver,
                  receiver.properties.contains(.notify),
                  writer.properties.contains(.write) || writer.properties.contains(.writeWithoutResponse) else { return }
            peripheral.setNotifyValue(true, for: receiver)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        onMain {
            guard characteristic.uuid == controlNotifyUUID else { return }
            self.connectTimer?.invalidate()
            if let error = error { self.failOut("notify subscription failed: \(error.localizedDescription)"); return }
            guard characteristic.isNotifying else { self.failOut("device refused notify subscription"); return }
            guard !self.opened else { return }
            self.opened = true
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "micproctl.verifiedPeripheralID")
            self.onOpen?()
        }
    }
    func write(_ data: Data) {
        bleQueue.async { [weak self] in
            guard let self = self, let peripheral = self.peripheral, let writer = self.writer else { return }
            peripheral.writeValue(data, for: writer, type: writer.properties.contains(.write) ? .withResponse : .withoutResponse)
        }
    }
    func close() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.scanTimer?.invalidate(); self.connectTimer?.invalidate(); self.bootstrapTimer?.invalidate()
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            self.central = nil
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { printDebug("notify error: \(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == batteryLevelUUID {
            if value.count == 1, let level = value.first, level <= 100 {
                onMain { self.driver?.context.batteryCharacteristicLevel = Int(level) }
            }
            return
        }
        let frames = streamBuffer.append(value)
        guard !frames.isEmpty else { return }
        onMain { for frame in frames { self.onFrames?(frame) } }
    }
}
