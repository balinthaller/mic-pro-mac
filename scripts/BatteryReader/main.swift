import Foundation
import IOBluetooth
if CommandLine.arguments.contains("--paired-devices") {
    let devices=(IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {$0.name?.contains("Mic Pro") == true}
    let rows=devices.map { ["name":$0.name ?? "", "bluetooth_address":$0.addressString?.uppercased().replacingOccurrences(of:"-",with:":") ?? ""] }
    if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {FileHandle.standardOutput.write(data)}
    exit(0)
}
if CommandLine.arguments.contains("--services") {
    let records = (SystemBattery.device()?.services as? [IOBluetoothSDPServiceRecord] ?? []).map { record -> [String: Any] in
        var channel: BluetoothRFCOMMChannelID = 0
        let result = record.getRFCOMMChannelID(&channel)
        return ["name": record.getServiceName() ?? "", "rfcomm_channel": result == 0 ? channel as Any : NSNull(),
                "classes": String(describing: record.getAttributeDataElement(1)),
                "known_uuid16": [UInt16(0x1101),0x111E,0x111F,0x1108,0x1112,0x110A,0x110B,0x1800,0x1801].filter { record.matchesUUID16($0) }.map { String(format: "%04X",$0) }]
    }
    if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted,.sortedKeys]) { FileHandle.standardOutput.write(data) }
    exit(0)
}
let level = SystemBattery.micProLevel()
let payload: [String: Any] = ["percent": level.map { $0 as Any } ?? NSNull()]
if let data = try? JSONSerialization.data(withJSONObject: payload) { FileHandle.standardOutput.write(data) }
