import Foundation
func check(_ condition:@autoclosure ()->Bool,_ message:String){if !condition(){fatalError(message)}}
let input:[String:Any] = ["bluetooth_address":"aa-bb-cc-dd-ee-01","serial_suffix":"test01"]
check(DeviceTarget.parse(input)?.address == "AA:BB:CC:DD:EE:01","normalize configured address")
check(DeviceTarget.parse(input)?.serialSuffix == "TEST01","normalize suffix")
for bad:[String:Any] in [[:],["bluetooth_address":"AA:BB:CC:DD:EE:01"],["serial_suffix":"TEST01"],["bluetooth_address":"00:00:00:00:00:00","serial_suffix":"TEST01"],["bluetooth_address":"AA:BB:CC:DD:EE:01","serial_suffix":""],["bluetooth_address":"AA:BB:CC:DD:EE:01","serial_suffix":"*"],["bluetooth_address":"garbage","serial_suffix":"TEST01"]] {check(DeviceTarget.parse(bad) == nil,"invalid target must fail closed")}
check(DeviceConfig.target == nil,"default must not select a device")
check(!DeviceConfig.experimentalFeaturesEnabled,"experimental controls must be opt-in")
check(!DeviceConfig.codexQuotaEnabled,"account reader must be opt-in")
print("PASS: target configuration and opt-in")
