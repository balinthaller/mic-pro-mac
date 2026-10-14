import Foundation
assert(tencentCRC(Array("123456789".utf8)) == 0x29B1)
let probe = tencentAcknowledgementProbe()
assert(probe.prefix(8) == Data([0xAA,0x10,2,0x40,0x31,0,0,0]))
var ack: [UInt8] = [0xAA,0x10,4,0x40,0x31,0,0,0]
let crc = tencentCRC(ack); ack += [UInt8(crc & 255), UInt8(crc >> 8)]
var stream = TencentStream()
assert(stream.append(Data(ack.prefix(4))).isEmpty)
let frames = stream.append(Data(ack.dropFirst(4)) + Data(ack))
assert(frames.count == 2 && frames.allSatisfy { $0.type == 4 && $0.command == 0x40 && $0.sequence == 0x31 && $0.payload.isEmpty })
var corrupt = ack; corrupt[9] ^= 1
assert(stream.append(Data(corrupt)).isEmpty)
assert(stream.append(Data(ack)).count == 1)
print("PASS: CRC known vector, safe type2 probe, fragmentation/coalescing, invalid CRC rejected and resynchronized")
