import Foundation
import AppKit
import CoreAudio

enum PowerMonitor {
    static func values(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32]? {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == 0, size % 4 == 0 else { return nil }
        if size == 0 { return [] }
        var result = [UInt32](repeating: 0, count: Int(size / 4))
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!) }
        return status == 0 ? result : nil
    }
    private static let cacheLock=NSLock()
    private static var cachedUsage: [String:Any]?,cachedAt:TimeInterval=0
    /// Only display callers opt into this short cache; safety and continuity checks stay fresh.
    static func usage(maxAge:TimeInterval=0) -> [String: Any] {
        let now=ProcessInfo.processInfo.systemUptime
        cacheLock.lock()
        if maxAge>0,let value=cachedUsage,now-cachedAt>=0,now-cachedAt<min(maxAge,1){cacheLock.unlock();return value}
        cacheLock.unlock()
        let result=readUsage()
        cacheLock.lock();cachedUsage=result;cachedAt=ProcessInfo.processInfo.systemUptime;cacheLock.unlock()
        return result
    }
    private static func readUsage() -> [String:Any] {
        guard let devices = try? AudioRouting.devices() else { return ["mic_input_running": NSNull(), "active_input_clients": NSNull()] }
        let targets = Set(devices.filter { $0.name.contains(DeviceConfig.serialSuffix) && $0.inputChannels > 0 }.map { $0.id })
        var clients = [String]()
        var clientDataAvailable = false
        if #available(macOS 14.2, *), let processes = values(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            clientDataAvailable = true
            for process in processes {
                let inputs = values(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) ?? []
                if !targets.isDisjoint(with: inputs), values(process, kAudioProcessPropertyIsRunningInput)?.first == 1 {
                    clients.append(AudioRouting.string(process, selector: kAudioProcessPropertyBundleID))
                }
            }
        }
        let states = targets.map { values($0, kAudioDevicePropertyDeviceIsRunningSomewhere)?.first }
        let running: Any
        if states.contains(where: { $0 == 1 }) { running = true }
        else if states.contains(where: { $0 == nil }) { running = NSNull() }
        else { running = false }
        let names = clients.map { bundle in
            if bundle == "cn.shandianshuo.desktop" { return "闪电说" }
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }), let name = app.localizedName { return name }
            return bundle.isEmpty ? "未识别的软件" : bundle
        }
        return ["active_input_client_names": clientDataAvailable ? names as Any : NSNull(), "mic_input_present": !targets.isEmpty, "mic_input_running": running,
                "active_input_clients": clientDataAvailable ? clients as Any : NSNull()]
    }
}
