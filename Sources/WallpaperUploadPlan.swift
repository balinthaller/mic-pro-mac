import Foundation
import CryptoKit

/// Bounded one-shot transfer, no retransmission, erase retry, or implicit rollback.
final class WallpaperUploadPlan {
    enum State: Equatable { case prepare, begin, data, end, ready, failed }
    private(set) var state: State = .prepare
    private(set) var error: String?
    private(set) var destructiveStarted = false
    let identity: Data
    let panel: Data
    let png: Data
    let md5: Data
    private var type: UInt8 = 2
    private var pending: (UInt16,UInt16)?
    private var message: UInt16 = 0xD0
    private var lastSent = -1
    private var waitingACK = false
    init(identity: Data,panel: Data,png: Data) throws {
        guard identity.count == 32,panel.count == 24960,(1...0x38000).contains(png.count) else { throw ProtocolError.invalidSettings }
        self.identity = identity;self.panel = panel;self.png = png;md5 = Data(Insecure.MD5.hash(data:panel))
    }
    var bytes: Data { type == 2 ? panel : png }
    var count: Int { (bytes.count+212)/213 }
    func requests() -> [Data] {
        guard pending == nil,state != .failed,state != .ready else { return [] }
        if state == .data {
            guard !waitingACK else { return [] }
            var result = [Data]()
            let stop = min(lastSent+10,count-1)
            for seq in (lastSent+1)...stop {
                let chunk = Data(bytes[(seq*213)..<min(bytes.count,(seq+1)*213)])
                let crc = wallpaperCRC(chunk)
                result.append(wallpaperFrame(0x21,encoded32(UInt32(seq))+Data([UInt8(chunk.count),0,UInt8(crc & 255),UInt8(crc >> 8)])+chunk))
            }
            lastSent = stop;waitingACK = true;return result
        }
        let command: UInt16;let body: Data
        if state == .prepare { command = 0x100A;body = identity+md5 }
        else if state == .begin {
            command = 0x20;let crc = wallpaperCRC(bytes)
            body = Data([type])+encoded32(0)+encoded32(UInt32(bytes.count))+Data([UInt8(crc & 255),UInt8(crc >> 8),10,0])+encoded32(UInt32(count))
            destructiveStarted = true
        } else { command = 0x22;body = Data([type])+encoded32(0) }
        message &+= 1;pending = (command,message)
        return [wallpaperFrame(command,Data([UInt8(message & 255),UInt8(message >> 8)])+body)]
    }
    func consume(_ frame: Frame) {
        guard frame.sequence >> 14 == 0 else { return }
        if state == .data {
            guard frame.command == 0x21,frame.payload.count == 5,waitingACK else { return }
            let seq = Int(little32(frame.payload,0));let flow = frame.payload[4]
            guard seq == lastSent,flow == 0 else { fail("文件流应答非预期；不自动重发或清除");return }
            waitingACK = false
            if lastSent == count-1 { state = .end }
            return
        }
        guard let pending = pending,frame.command == pending.0,frame.payload.count == 3,little16(frame.payload,0) == pending.1 else { return }
        self.pending = nil
        guard frame.payload[2] == 0 else { fail("设备拒绝壁纸传输阶段");return }
        if state == .prepare { state = .begin }
        else if state == .begin { state = .data;lastSent = -1;waitingACK = false }
        else if state == .end {
            if type == 2 { type = 3;state = .begin } else { state = .ready }
        }
    }
    func timeout() { fail("壁纸传输超时，结果可能不确定；不自动重试或假定恢复") }
    private func fail(_ value: String) { state = .failed;error = value }
}
