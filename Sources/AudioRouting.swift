import Foundation
import CoreAudio

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}
enum AudioDirection { case input, output }
struct AudioRoutingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct AudioRouting {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
        var property = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        guard result == noErr else { return "" }
        return value as String
    }
    static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func devices() throws -> [AudioDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { throw AudioRoutingError(message: "无法读取音频设备列表") }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { throw AudioRoutingError(message: "音频设备列表读取失败（\(result)）") }
        return ids.map { id in
            AudioDevice(id: id, uid: string(id, selector: kAudioDevicePropertyDeviceUID), name: string(id, selector: kAudioObjectPropertyName), inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput), outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput))
        }.filter { !$0.uid.isEmpty }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func current(_ direction: AudioDirection) throws -> AudioDeviceID {
        try current(selector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }
    static func current(selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var property = address(selector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id)
        guard result == noErr else { throw AudioRoutingError(message: "读取当前音频选择失败（\(result)）") }
        return id
    }
    private static func set(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws {
        var property = address(selector)
        var value = id
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        guard result == noErr else { throw AudioRoutingError(message: "切换失败：设备可能已断开，或不能作为默认设备（\(result)）") }
        guard try current(selector: selector) == id else { throw AudioRoutingError(message: "系统尚未采用所选音频设备，请刷新后重试") }
    }
    static func select(uid: String, direction: AudioDirection) throws {
        guard let device = try devices().first(where: {$0.uid == uid}),
              direction == .input ? device.inputChannels > 0 : device.outputChannels > 0 else { throw AudioRoutingError(message: "所选设备已断开或不支持此方向") }
        if direction == .input {
            try set(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
        } else {
            // Keep playback and system alerts on the chosen output; input is independent.
            let oldOutput = try current(.output)
            let oldSystem = try current(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
            do {
                try set(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
                try set(device.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
            } catch {
                try? set(oldOutput, selector: kAudioHardwarePropertyDefaultOutputDevice)
                try? set(oldSystem, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
                throw error
            }
        }
    }
}
