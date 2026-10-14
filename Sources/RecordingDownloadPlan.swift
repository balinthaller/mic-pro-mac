import Foundation

/// Firmware v2 read stream: START 35, DATA 43, END 38; no deletion or upload.
final class RecordingDownloadPlan {
    enum State { case safetyStart, start, receiving, verifying, safetyEnd, ending, ready, failed }
    private(set) var state: State = .safetyStart
    private(set) var error: String?
    private var verified = false
    var file: Data? { verified ? try? Data(contentsOf:spool.url) : nil }
    var fileURL: URL? { verified ? spool.url : nil }
    let spool: RecordingSpool
    let asynchronousValidation: Bool
    var onUpdate: (() -> Void)?
    private var transferStarted = Date()
    private(set) var size = 0
    let identifier: Data
    let identity: Data
    private var message: UInt16 = 0xE0
    private var pending: (UInt16,UInt16)?
    private var block = 0
    private var count = 0
    private(set) var wholeCRC: UInt16 = 0
    private(set) var deviceCRCMatches: Bool?
    private var firstDataAt: Date?
    private var lastDataAt: Date?
    let maxBytes: Int
    private var sawFinal = false
    private var resume = 0
    private(set) var resumes = 0
    init(metadata: Data, identity: Data, asynchronousValidation: Bool = true, maxBytes: Int = 512*1024*1024) throws {
        guard (1...512*1024*1024).contains(maxBytes) else { throw ProtocolError.invalidSettings }; self.maxBytes=maxBytes
        self.asynchronousValidation = asynchronousValidation
        spool = try RecordingSpool()
        guard identity.count == 32 else { throw ProtocolError.invalidSettings }; self.identity = identity
        guard metadata.count == 72, metadata.prefix(64).contains(0), metadata[68] == 0, metadata[69] == 0 else { throw ProtocolError.invalidSettings }
        identifier = Data(metadata.prefix(68))
    }
    func nextRequest() -> Data? {
        guard pending == nil else { return nil }
        let cmd: UInt16; let body: Data
        switch state {
        case .safetyStart, .safetyEnd: cmd = 0x1014; body = Data([0x17,0x10,0,0]) + identity
        case .start: cmd = 0x35; body = identifier + Data([200,0,resume == 0 ? 0 : 1]) + encoded32(UInt32(resume))
        case .ending: cmd = 0x38; body = identifier + Data([0])
        default: return nil
        }
        message &+= 1; pending = (cmd,message)
        return wallpaperFrame(cmd,Data([UInt8(message & 255),UInt8(message >> 8)]) + body)
    }
    func consume(_ frame: Frame) {
        guard frame.sequence >> 14 == 0 else { return }
        if let pending = pending, frame.command == pending.0, frame.payload.count >= 3, little16(frame.payload,0) == pending.1 {
            self.pending = nil
            guard frame.payload[2] == 0 else { fail("下载请求被拒绝，状态=\(frame.payload[2])"); return }
            let body = Data(frame.payload.dropFirst(3))
            if state == .safetyStart || state == .safetyEnd {
                guard body.count == 55, body.prefix(32) == identity, little16(body,32) == 0x1017, body[37] == 0 else { fail("无法确认传输后自动删除关闭；停止下载，不改设备设置"); return }
                state = state == .safetyStart ? .start : .ending
            } else if state == .start {
                guard body.count == 86, body.prefix(68) == identifier, body[84] == 2, body[85] == 0, little32(body,74) == 0 else { fail("录音传输清单格式未知"); return }
                let newBlock = Int(little16(body,68)); let newSize = Int(little32(body,70)); let newCount = Int(little32(body,78)); let newCRC = little16(body,82)
                if resume != 0 && (newBlock != block || newSize != size || newCount != count || newCRC != wholeCRC) { fail("续传清单变化"); return }
                block = newBlock; size = newSize; count = newCount; wholeCRC = newCRC
                guard (1...200).contains(block), (1...maxBytes).contains(size), count == (size + block - 1)/block else { fail("录音传输清单无效或超过请求的字节上限；原录音保留"); return }
                do { try spool.configure(total:size,block:block,count:count) } catch { fail("录音临时文件配置失败");return }
                state = .receiving
            } else {
                guard body.isEmpty, verified, spool.complete else { fail("下载结束回复无效"); return }
                state = .ready
            }
            return
        }
        if frame.command == 0x39 {
            if state == .receiving, frame.payload.count == 69, frame.payload.prefix(68) == identifier, frame.payload[68] == 16, resumes < 8 {
                let next = spool.contiguous
                if next > resume && next < count { resume = next; resumes += 1; state = .start; pending = nil; return }
            }
            fail("设备中止录音传输，原因=\(frame.payload.last ?? 255)，已收到\(spool.packets)/\(count)包、\(spool.received)/\(size)字节，final=\(sawFinal)"); return }
        guard state == .receiving, frame.command == 0x43 else { return }
        let p = frame.payload
        guard p.count >= 9 else { fail("录音数据包不完整"); return }
        let seq = Int(little32(p,2)); let bytes = Data(p.dropFirst(8))
        guard seq < count, p[6] <= 1, p[7] <= 1, bytes.count == (seq == count-1 ? size - seq*block : block),
              (p[6] == 1) == (seq == count-1), wallpaperCRC(Data(p.dropFirst(2))) == little16(p,0) else { fail("录音数据包长度/序号/CRC无效"); return }
        let receivedBefore=spool.received
        do { try spool.put(seq,bytes) } catch { fail("录音分包重复冲突或临时文件写入失败");return }
        if spool.received>receivedBefore { if firstDataAt == nil {firstDataAt=Date()};lastDataAt=Date() }
        sawFinal = sawFinal || p[6] == 1
        if spool.complete && sawFinal {
            state = .verifying
            if asynchronousValidation {
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    guard let self = self else { return }
                    let result = Result { try self.spool.validate() }
                    DispatchQueue.main.async { self.finishValidation(result);self.onUpdate?() }
                }
            } else { finishValidation(Result { try spool.validate() }) }
        }
    }
    private func finishValidation(_ result: Result<OggFileValidation,Error>) {
        guard state == .verifying else { return }
        switch result {
        case .success(let validation):deviceCRCMatches = validation.crc16 == wholeCRC;verified=true;state = .safetyEnd
        case .failure:fail("录音长度或OGG页面完整校验失败")
        }
    }
    var progress: RecordingTransferProgress {
        let phase: String
        switch state {
        case .receiving:phase="蓝牙下载"
        case .verifying:phase="校验录音"
        case .safetyEnd,.ending:phase="确认保留原文件"
        case .ready:phase="完成"
        case .failed:phase=error ?? "未完成"
        default:phase="准备下载"
        }
        return RecordingTransferProgress(received:spool.received,total:size,started:transferStarted,phase:phase)
    }
    var measurements: [String:Any] {
        let span=firstDataAt.flatMap { first in lastDataAt.map{$0.timeIntervalSince(first)} }
        return ["payload_bytes_per_packet":block,"unique_packets":spool.packets,"resumes":resumes,"download_max_bytes":maxBytes,
                "data_window_seconds":span as Any? ?? NSNull(),"data_window_kib_per_second":span.flatMap{$0>0 ? Double(spool.received)/$0/1024 : nil} as Any? ?? NSNull(),
                "data_window_basis":"first_unique_packet_to_last_unique_packet; excludes auth/list/verification/close"]
    }
    var deadlineSeconds: TimeInterval { min(21600,max(180,Double(size)/4096+60)) }
    func publish(to target: URL) throws { guard state == .ready,verified else { throw ProtocolError.invalidSettings };try spool.publish(to:target) }
    func cancel() { fail("已取消，原录音保留。") }
    func timeout() { fail("录音下载超时；不发布不完整文件") }
    private func fail(_ value: String) { error = value; state = .failed;verified=false;spool.discard() }
}

/// Ogg pages carry their own non-reflected CRC32. Require complete pages and EOS.
func validOggFile(_ data: Data) -> Bool {
    var offset = 0; var finalFlags: UInt8 = 0
    guard data.count >= 27 else { return false }
    while offset < data.count {
        guard offset + 27 <= data.count, Data(data[offset..<(offset+4)]) == Data("OggS".utf8), data[offset+4] == 0 else { return false }
        let segments = Int(data[offset+26]); guard offset + 27 + segments <= data.count else { return false }
        let payload = data[(offset+27)..<(offset+27+segments)].reduce(0){$0+Int($1)}
        let end = offset + 27 + segments + payload; guard end <= data.count else { return false }
        let expected = little32(data,offset+22); var crc: UInt32 = 0
        for i in offset..<end {
            let byte: UInt8 = (offset+22..<offset+26).contains(i) ? 0 : data[i]
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x80000000 == 0 ? crc << 1 : (crc << 1) ^ 0x04C11DB7 }
        }
        guard crc == expected else { return false }
        finalFlags = data[offset+5]; offset = end
    }
    return offset == data.count && finalFlags & 4 != 0
}
