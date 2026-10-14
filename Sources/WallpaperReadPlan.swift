import Foundation

func wallpaperCRC(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= UInt16(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
    }
    return crc ^ 0xFFFF
}
func little32(_ data: Data, _ at: Int) -> UInt32 {
    UInt32(data[at]) | UInt32(data[at+1]) << 8 | UInt32(data[at+2]) << 16 | UInt32(data[at+3]) << 24
}
func little16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at+1]) << 8 }
func encoded32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0*8)) & 255) }) }
func wallpaperFrame(_ command: UInt16, _ payload: Data) -> Data {
    Data([0xFE,0xEF,1,UInt8(command & 255),UInt8(command >> 8),0,0,UInt8(payload.count & 255),UInt8(payload.count >> 8)]) + payload
}

/// Read-only file transport: no upload BEGIN/DATA/END, refresh or delete builders.
final class WallpaperReadPlan {
    enum State: Equatable { case selecting, manifest, receiving, ready, failed }
    private(set) var state: State = .selecting
    private(set) var error: String?
    private(set) var manifest: Data?
    private(set) var file: Data?
    private(set) var missingCRC = false
    private var pending: (UInt16,UInt16)?
    private var message: UInt16 = 0xB0
    private var size = 0
    private var count = 0
    private var interval = 10
    private var wholeCRC: UInt16 = 0
    private var chunks = [Int:Data]()
    private var contiguous = -1
    private var lastACK = -1
    let identity: Data
    init(identity: Data) { self.identity = identity }
    func nextRequest() -> Data? {
        guard pending == nil, identity.count == 32 else { return nil }
        let command: UInt16; let body: Data
        if state == .selecting { command = 0x100B; body = identity + encoded32(0) }
        else if state == .manifest { command = 0x30; body = Data([2]) + encoded32(0) }
        else { return nil }
        message &+= 1; pending = (command,message)
        return wallpaperFrame(command,Data([UInt8(message & 255),UInt8(message >> 8)]) + body)
    }
    func consume(_ frame: Frame) -> Data? {
        guard frame.sequence >> 14 == 0 else { fail("暂不支持分段文件帧"); return nil }
        if state == .selecting || state == .manifest {
            guard let pending = pending, frame.command == pending.0, frame.payload.count >= 3, little16(frame.payload,0) == pending.1 else { return nil }
            self.pending = nil
            guard frame.payload[2] == 0 else { fail("设备拒绝壁纸读取"); return nil }
            let body = Data(frame.payload.dropFirst(3))
            if state == .selecting { guard body.isEmpty else { fail("选择回复格式未知"); return nil }; state = .manifest }
            else {
                guard body.count == 17, body[0] == 3, little32(body,1) == 0 else { fail("壁纸元数据清单格式不匹配"); return nil }
                size = Int(little32(body,5)); wholeCRC = little16(body,9); interval = Int(little16(body,11)); count = Int(little32(body,13))
                guard (1...0x38000).contains(size), (1...5000).contains(count), (1...100).contains(interval), count <= size, size <= count*213 else { fail("壁纸清单范围不合法"); return nil }
                manifest = body; missingCRC = wholeCRC == 0; state = .receiving
            }
            return nil
        }
        guard state == .receiving else { return nil }
        if frame.command == 0x32 {
            if chunks.count != count { fail("设备结束传输，但文件不完整") }
            return nil
        }
        guard frame.command == 0x31, frame.payload.count >= 9 else { return nil }
        let seq = Int(little32(frame.payload,0)); let length = Int(little16(frame.payload,4)); let crc = little16(frame.payload,6)
        let bytes = Data(frame.payload.dropFirst(8))
        guard seq < count, seq <= contiguous + 101, bytes.count == length, (1...213).contains(length) else { fail("壁纸分包序号/长度不合法"); return nil }
        guard crc == 0 || wallpaperCRC(bytes) == crc else { fail("壁纸分包CRC错误"); return nil }
        if crc == 0 { missingCRC = true }
        if let previous = chunks[seq], previous != bytes { fail("壁纸重复分包内容冲突"); return nil }
        chunks[seq] = bytes
        guard chunks.values.reduce(0, { $0 + $1.count }) <= size else { fail("壁纸总长度超出清单"); return nil }
        while chunks[contiguous+1] != nil { contiguous += 1 }
        if chunks.count == count {
            var result = Data(); for i in 0..<count { guard let bytes = chunks[i] else { return nil }; result += bytes }
            guard result.count == size, wholeCRC == 0 || wallpaperCRC(result) == wholeCRC else { fail("壁纸完整长度/CRC错误"); return nil }
            file = result; state = .ready
        }
        if contiguous >= 0 && (state == .ready || contiguous - lastACK >= interval) {
            lastACK = contiguous
            return wallpaperFrame(0x31,encoded32(UInt32(contiguous)))
        }
        return nil
    }
    func timeout() { fail("壁纸读取超时，未自动重试或发送清除命令") }
    private func fail(_ value: String) { state = .failed; error = value }
}
