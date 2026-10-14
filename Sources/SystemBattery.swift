import Foundation
import IOBluetooth
import ObjectiveC

// macOS exposes its Bluetooth UI battery cache through an undocumented getter.
// Resolve at runtime and check its ABI before calling; never invoke setters.
enum SystemBattery {
    static func device() -> IOBluetoothDevice? {
        guard DeviceConfig.target != nil else { return nil }
        return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: {
            $0.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") == DeviceConfig.address
            && $0.name?.contains(DeviceConfig.serialSuffix) == true
        })
    }
    static func micProLevel() -> Int? {
        guard let device = device(), device.isConnected() else { return nil }
        let selector = NSSelectorFromString("batteryPercentSingle")
        guard device.responds(to: selector), let cls = object_getClass(device),
              let method = class_getInstanceMethod(cls, selector), method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "C", let imp = device.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        let value = unsafeBitCast(imp, to: Getter.self)(device, selector)
        // A reconnect resets the system cache to zero before a report arrives.
        // Zero cannot currently be distinguished from an uninitialized cache.
        return (1...100).contains(value) ? Int(value) : nil
    }
}
