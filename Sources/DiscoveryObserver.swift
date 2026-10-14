import Foundation
import CoreBluetooth

/// Its private central observes advertisements and one OS connection snapshot.
/// It never opens a connection or accesses characteristics.
final class DiscoveryObserver: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var deadline: Timer?
    private var finished = false
    private var systemEnumerationPerformed = false
    private var model: DiscoveryObservationModel
    private let completion: ([String:Any]) -> Void
    init(verifiedIdentifier: UUID?, completion: @escaping ([String:Any]) -> Void) {
        model=DiscoveryObservationModel(verifiedIdentifier:verifiedIdentifier,startedAt:Date());self.completion=completion
        super.init()
        deadline=Timer(timeInterval:DiscoveryObservationModel.duration,repeats:false) { [weak self] _ in self?.stop(reason:"deadline") }
        RunLoop.main.add(deadline!,forMode:.common)
        manager=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
    }
    func stop(reason: String = "user_stopped") {
        guard !finished else { return };finished=true
        deadline?.invalidate();deadline=nil
        manager?.stopScan();manager?.delegate=nil;manager=nil
        completion(model.report(endedAt:Date(),reason:reason))
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !finished, central === manager else { return }
        guard Date().timeIntervalSince(model.startedAt) < DiscoveryObservationModel.duration else { stop(reason:"deadline");return }
        switch central.state {
        case .poweredOn:
            if !systemEnumerationPerformed {
                systemEnumerationPerformed=true
                let existing=central.retrieveConnectedPeripherals(withServices:[serviceID])
                model.observeSystemConnected(existing.map { peripheral in
                    let state:String
                    switch peripheral.state {
                    case .disconnected: state="disconnected"
                    case .connecting: state="connecting"
                    case .connected: state="connected"
                    case .disconnecting: state="disconnecting"
                    @unknown default: state="unknown"
                    }
                    return (identifier:peripheral.identifier,name:peripheral.name,state:state)
                },at:Date())
            }
            central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])
        case .unauthorized: stop(reason:"bluetooth_unauthorized")
        case .unsupported: stop(reason:"bluetooth_unsupported")
        case .poweredOff: stop(reason:"bluetooth_powered_off")
        case .unknown,.resetting: break
        @unknown default: stop(reason:"bluetooth_unknown_state")
        }
    }
    func centralManager(_ central: CBCentralManager,didDiscover peripheral: CBPeripheral,advertisementData: [String:Any],rssi RSSI: NSNumber) {
        guard !finished, central === manager else { return }
        guard Date().timeIntervalSince(model.startedAt) < DiscoveryObservationModel.duration else { stop(reason:"deadline");return }
        let serviceData=advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID:Data] ?? [:]
        let services=(advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []) + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []) + Array(serviceData.keys)
        model.observe(DiscoveryAdvertisement(identifier:peripheral.identifier,
            localName:advertisementData[CBAdvertisementDataLocalNameKey] as? String,peripheralName:peripheral.name,
            services:services.map { $0.uuidString },manufacturer:advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            connectable:(advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,rssi:RSSI.intValue),at:Date())
    }
    deinit { deadline?.invalidate();manager?.stopScan();manager?.delegate=nil }
}

extension Probe {
    @objc func observeDiscoveryBroadcasts() { startDiscoveryObservation() }
    func startDiscoveryObservation(id: String? = nil) {
        guard !deviceTransactionBusy, peripheral == nil, !controlWanted, central?.isScanning != true else {
            log("广播观察拒绝：其他操作或BLE连接进行中；未断开任何连接。")
            if let id=id { agentReply(id,["ok":false,"error":"busy_or_ble_active"]) };return
        }
        discoveryObserver?.stop(reason:"replaced_by_new_observation")
        discoveryObserver=nil
        log("开始60秒BLE广播观察：不会连接设备；名称匹配不代表手机App兼容广播。")
        let verified=UserDefaults.standard.string(forKey:"verifiedPeripheralID").flatMap { UUID(uuidString:$0) }
        discoveryObserver=DiscoveryObserver(verifiedIdentifier:verified) { [weak self] report in
            guard let self=self else { return }
            do {
                let folder=URL(fileURLWithPath:projectRoot+"/logs/discovery-observation")
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let path=folder.appendingPathComponent(UUID().uuidString+".json")
                let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                // Exclusive owner-only creation prevents a transient readable report.
                guard FileManager.default.createFile(atPath:path.path,contents:data,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
                self.log("BLE广播观察结束：\(report["stop_reason"] ?? "unknown")，目标广播\(report["target_advertisement_count"] ?? 0)条，其他广播仅计数\(report["other_advertisement_count"] ?? 0)条。报告=\(path.path)；未观察到不证明没有广播。")
                if let id=id {
                    let reason=report["stop_reason"] as? String ?? "unknown"
                    let completed=["deadline","user_stopped","replaced_by_new_observation"].contains(reason)
                    self.agentReply(id,["ok":completed,"report_path":path.path,"observation":report,
                                        "error":completed ? NSNull() : reason as Any])
                }
            } catch {
                self.log("BLE广播观察报告保存失败：\(error.localizedDescription)")
                if let id=id { self.agentReply(id,["ok":false,"error":"observation_report_write_failed"]) }
            }
        }
    }
    func stopDiscoveryObservation() { discoveryObserver?.stop();discoveryObserver=nil }
}
