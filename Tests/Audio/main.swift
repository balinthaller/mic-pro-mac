import Foundation
import CoreAudio
let list = try AudioRouting.devices()
let input = try AudioRouting.current(.input)
let output = try AudioRouting.current(.output)
let systemOutput = try AudioRouting.current(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
for d in list { print("\(d.id) \(d.name) input=\(d.inputChannels) output=\(d.outputChannels) \(d.id == input ? "[INPUT]" : "") \(d.id == output ? "[OUTPUT]" : "")") }
func roundtrip() throws {
    guard let original = list.first(where: {$0.id == input}), let speaker = list.first(where: {$0.id == output}), let alternate = list.first(where: {$0.id != input && $0.inputChannels > 0 && ($0.name == "BlackHole 2ch" || $0.name.contains("MacBook Pro"))}) else { fatalError("no alternate input available") }
    defer { try? AudioRouting.select(uid: original.uid, direction: .input) }
    try AudioRouting.select(uid: alternate.uid, direction: .input)
    guard try AudioRouting.current(.input) == alternate.id else { throw AudioRoutingError(message: "input did not change") }
    guard try AudioRouting.current(.output) == output else { throw AudioRoutingError(message: "output unexpectedly changed") }
    guard try AudioRouting.current(selector: kAudioHardwarePropertyDefaultSystemOutputDevice) == systemOutput else { throw AudioRoutingError(message: "system output unexpectedly changed") }
    try AudioRouting.select(uid: original.uid, direction: .input)
    if output == systemOutput { try AudioRouting.select(uid: speaker.uid, direction: .output) }
    guard try AudioRouting.current(.input) == input else { throw AudioRoutingError(message: "input was not preserved") }
    guard try AudioRouting.current(.output) == output else { throw AudioRoutingError(message: "output unexpectedly changed") }
    print("PASS: changed input independently, restored input, selected output without changing input")
}

if CommandLine.arguments.contains("--roundtrip") { try roundtrip() }
