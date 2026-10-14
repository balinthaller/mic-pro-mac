import Foundation
struct Frame { let command: UInt16; let sequence: UInt16; let payload: Data }
struct FrameStream {
    private var buffer = [UInt8]()
    mutating func append(_ data: Data) -> [Frame] {
        buffer += data
        var frames = [Frame]()
        while buffer.count >= 2 {
            guard buffer[0] == 0xFE && buffer[1] == 0xEF else { buffer.removeFirst(); continue }
            guard buffer.count >= 9 else { break }
            guard buffer[2] == 1 else { buffer.removeFirst(); continue }
            let length = Int(buffer[7]) | Int(buffer[8]) << 8
            guard length <= 221 else { buffer.removeFirst(); continue }
            guard buffer.count >= 9 + length else { break }
            frames.append(Frame(command: UInt16(buffer[3]) | UInt16(buffer[4]) << 8,
                                sequence: UInt16(buffer[5]) | UInt16(buffer[6]) << 8,
                                payload: Data(buffer[9..<(9+length)])))
            buffer.removeFirst(9 + length)
        }
        return frames
    }
}
enum ProtocolError: Error { case invalidSettings }
func vibrationSnapshot(_ data: Data, enabled: Bool) throws -> Data {
    guard data.count == 12 else { throw ProtocolError.invalidSettings }
    let limits: [UInt8] = [1,1,1,1,1,2,3,1,1,1,1,1]
    guard zip(data, limits).allSatisfy({ $0 <= $1 }) else { throw ProtocolError.invalidSettings }
    var result = data; result[9] = enabled ? 1 : 0; return result
}
func settingsResponse(_ body: Data, identity: Data, group: UInt16) throws -> Data {
    let size = group == 0x1000 ? 6 : group == 0x1012 ? 12 : 0
    guard identity.count == 32, size != 0, body.count == 37 + size,
          body.prefix(32) == identity, body[32] == UInt8(group & 255), body[33] == UInt8(group >> 8),
          body.suffix(3) == Data([0,0,0]) else { throw ProtocolError.invalidSettings }
    let values = Data(body[34..<(34+size)])
    if group == 0x1012 { _ = try vibrationSnapshot(values, enabled: values[9] == 1) }
    else {
        let bytes = [UInt8](values)
        guard bytes[0] <= 1, bytes[1] <= 1, (-12...12).contains(Int(Int8(bitPattern:bytes[2]))), bytes[3] <= 2, bytes[4] <= 1, bytes[5] <= 2 else { throw ProtocolError.invalidSettings }
    }
    return values
}
// Protocol facts independently recovered from the published Mic Pro Remote v2 APK.
// Count + group:u16le + identity:32 bytes + the complete twelve-byte More value.
func moreSettingsWriteBody(identity: Data, values: Data) throws -> Data {
    guard identity.count == 32 else { throw ProtocolError.invalidSettings }
    _ = try vibrationSnapshot(values, enabled: values.count == 12 && values[9] == 1)
    return Data([1, 0x12, 0x10]) + identity + values
}
enum MoreToggleField: Int { case childLock = 8, vibration = 9, led = 10 }
func moreToggleSnapshot(_ data: Data, field: MoreToggleField, enabled: Bool) throws -> Data {
    guard data.count == 12 else { throw ProtocolError.invalidSettings }
    var result = try vibrationSnapshot(data, enabled: data[9] == 1)
    result[field.rawValue] = enabled ? 1 : 0
    return result
}

func noiseFeedbackSnapshot(_ values: Data) throws -> Data {
    guard values.count == 6 else { throw ProtocolError.invalidSettings }
    let body = Data(repeating: 0, count: 32) + Data([0,0x10]) + values + Data([0,0,0])
    _ = try settingsResponse(body, identity: Data(repeating: 0, count: 32), group: 0x1000)
    var target = values; target[3] = values[3] == 1 ? 2 : 1
    return target
}
func commonSettingsWriteBody(identity: Data, values: Data) throws -> Data {
    guard identity.count == 32 else { throw ProtocolError.invalidSettings }
    _ = try noiseFeedbackSnapshot(values)
    return Data([1,0,0x10]) + identity + values
}
