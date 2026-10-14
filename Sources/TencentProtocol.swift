import Foundation

func tencentCRC(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc &<< 1 : (crc &<< 1) ^ 0x1021 }
    }
    return crc
}
// Type2 is acknowledged by firmware but does not run type1-only GET_DEVICE_INFO.
// A type1 command40 also changes bound state; it must not be treated as read-only.
func tencentAcknowledgementProbe(sequence: UInt8 = 0x31) -> Data {
    var frame: [UInt8] = [0xAA,0x10,2,0x40,sequence,0,0,0]
    let crc = tencentCRC(frame); frame += [UInt8(crc & 255), UInt8(crc >> 8)]
    return Data(frame)
}
struct TencentFrame { let type: UInt8; let command: UInt8; let sequence: UInt8; let payload: Data }
struct TencentStream {
    private var bytes = [UInt8]()
    mutating func append(_ data: Data) -> [TencentFrame] {
        bytes += data; var result = [TencentFrame]()
        while bytes.count >= 8 {
            guard bytes[0] == 0xAA, bytes[1] == 0x10 else { bytes.removeFirst(); continue }
            let length = Int(bytes[6]) | Int(bytes[7]) << 8
            guard length + 10 <= 256 else { bytes.removeFirst(); continue }
            guard bytes.count >= length + 10 else { break }
            let crc = UInt16(bytes[8 + length]) | UInt16(bytes[9 + length]) << 8
            guard tencentCRC(Array(bytes.prefix(8 + length))) == crc else { bytes.removeFirst(); continue }
            result.append(TencentFrame(type: bytes[2], command: bytes[3], sequence: bytes[4], payload: Data(bytes[8..<(8 + length)])))
            bytes.removeFirst(10 + length)
        }
        return result
    }
}
