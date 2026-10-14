import Foundation

struct SerialPacket {
    let command: UInt8
    let payload: Data
}

struct SerialPacketStream {
    private var buffer = [UInt8]()
    mutating func append(_ data: Data) -> [SerialPacket] {
        buffer += data
        var packets: [SerialPacket] = []
        while buffer.count >= 8 {
            guard buffer[0] == 0xFC, buffer[1] == 0xEF, buffer[2] == 0xFD else { buffer.removeFirst(); continue }
            let length = Int(buffer[6]) | Int(buffer[7]) << 8
            guard length <= 4096 else { buffer.removeFirst(); continue }
            guard buffer.count >= length + 8 else { break }
            // F1 carries encoded microphone audio. Consume without retaining or logging it.
            if buffer[3] != 0xF1 { packets.append(SerialPacket(command: buffer[3], payload: Data(buffer[8..<(8 + length)]))) }
            buffer.removeFirst(8 + length)
        }
        return packets
    }
}

func serialNoiseRequest(_ value: UInt8? = nil) -> Data {
    Data([0xFE,0xEF,0xFD,0xF3,0xFF,0,6,0,value == nil ? 5 : 0x82,4,value ?? 0,0,0,0])
}

func serialNoiseValue(_ packet: SerialPacket) -> UInt8? {
    guard packet.command == 0xF3, packet.payload.count == 6,
          packet.payload[0] == 5, packet.payload[1] == 4, packet.payload[2] <= 2,
          packet.payload.suffix(3) == Data([0,0,0]) else { return nil }
    return packet.payload[2]
}
