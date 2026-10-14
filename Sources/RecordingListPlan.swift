import Foundation

/// Read-only allowlist: 002A list and 101F metadata. Never constructs delete 0033.
final class RecordingListPlan {
    enum State { case list, info, ready, failed }
    private(set) var state: State = .list
    private(set) var error: String?
    private(set) var total = 0
    private(set) var reportedTotal = 0
    private(set) var listingComplete = false
    private var offset = 0
    private var seen = Set<Data>()
    private let scanAll: Bool
    let pageSize = 20
    private(set) var responses = 0
    private(set) var entries = [Data]()
    private(set) var metadata = [Data]()
    private var message: UInt16 = 0xD0
    private var pending: (UInt16,UInt16)?
    private var index = 0
    private var detailIndices = [Int]()
    let selectedDetailsOnly: Bool
    private let preferredFileID: UInt32?
    private let preferredFragment: UInt16?
    init(preferredFileID: UInt32? = nil, preferredFragment: UInt16? = nil, scanAll: Bool = true, selectedDetailsOnly: Bool = false) {
        self.preferredFileID = preferredFileID; self.preferredFragment = preferredFragment; self.scanAll = scanAll
        self.selectedDetailsOnly = selectedDetailsOnly
        if selectedDetailsOnly && preferredFileID == nil { state = .failed; error = "单文件详情需要明确录音身份" }
    }
    func nextRequest() -> Data? {
        guard pending == nil else { return nil }
        let command: UInt16; let body: Data
        switch state {
        case .list: command = 0x2A; body = Data(repeating:0,count:9) + Data([UInt8(offset & 255),UInt8(offset >> 8),UInt8(scanAll ? pageSize : 5),0])
        case .info: command = 0x101F; body = entries[detailIndices[index]]
        default: return nil
        }
        message &+= 1; pending = (command,message)
        return wallpaperFrame(command,Data([UInt8(message & 255),UInt8(message >> 8)]) + body)
    }
    func consume(_ frame: Frame) {
        guard let pending = pending, frame.command == pending.0, frame.sequence >> 14 == 0,
              frame.payload.count >= 3, little16(frame.payload,0) == pending.1 else { return }
        self.pending = nil; responses += 1
        guard frame.payload[2] == 0 else { fail("录音读取被拒绝，状态=\(frame.payload[2])"); return }
        let body = Data(frame.payload.dropFirst(3))
        if state == .list {
            guard body.count >= 6 else { fail("录音列表头不完整"); return }
            reportedTotal = Int(little16(body,0)); let count = Int(body[4])
            guard little16(body,2) == 0, body[5] == 0, count <= (scanAll ? pageSize : 5), body.count == 6 + count*8 else { fail("录音列表分页格式未知"); return }
            let page = (0..<count).map { Data(body[(6+$0*8)..<(14+$0*8)]) }
            for entry in page {
                guard seen.insert(entry).inserted else { fail("设备返回重复分页，停止以免漏列/循环"); return }
                entries.append(entry)
            }
            guard entries.count <= 4096 else { fail("录音索引超过4096条保护上限"); return }
            offset += count; total = entries.count
            // Probe until an empty page: the header may describe only this index/page.
            if scanAll && count > 0 { return }
            listingComplete = scanAll
            // Firmware START reuses its most recently queried file-info cache.
            // Query the selected recording last so its size/CRC cannot belong to another file.
            if let id = preferredFileID {
                let matches = entries.indices.filter { little32(entries[$0],0) == id && (preferredFragment == nil || little16(entries[$0],6) == preferredFragment) }
                guard matches.count == 1, let i = matches.first else { fail(matches.isEmpty ? "所选录音/分段已不在索引中" : "同一录音有多个分段，请提供 --fragment"); return }
                let selected = entries.remove(at:i); entries.append(selected)
            }
            detailIndices = selectedDetailsOnly ? (entries.isEmpty ? [] : [entries.count-1]) : Array(entries.indices)
            state = entries.isEmpty ? .ready : .info
        } else {
            guard body.count == 72 else { fail("录音详细信息长度未知：\(body.count)"); return }
            guard little32(body,64) == little32(entries[detailIndices[index]],0) else { fail("录音详细信息身份不匹配"); return }
            metadata.append(body); index += 1
            state = index == detailIndices.count ? .ready : .info
        }
    }
    var selectedMetadata: Data? {
        guard state == .ready, let id = preferredFileID,
              let offset = detailIndices.firstIndex(where: { little32(entries[$0],0) == id && (preferredFragment == nil || little16(entries[$0],6) == preferredFragment) }),
              offset < metadata.count else { return nil }
        return metadata[offset]
    }
    var metadataComplete: Bool { state == .ready && listingComplete && metadata.count == entries.count }
    var result: [[String:Any]] {
        let resultIndices = selectedDetailsOnly ? detailIndices : Array(entries.indices)
        let metadataOffsets = Dictionary(uniqueKeysWithValues:detailIndices.enumerated().map { ($0.element,$0.offset) })
        return resultIndices.map { entryIndex in
            let entry = entries[entryIndex]
            var item: [String:Any] = ["file_time": little32(entry,0), "duration_raw":little16(entry,4),"fragment_raw":little16(entry,6)]
            if let offset = metadataOffsets[entryIndex], offset < metadata.count {
                let data = metadata[offset]
                item["name"] = String(decoding:data.prefix(64).prefix(while:{$0 != 0}),as:UTF8.self)
                item["file_id"] = little32(data,64)
                item["metadata_hex"] = data.map { String(format:"%02x",$0) }.joined()
            }
            return item
        }
    }
    func timeout() { fail("录音只读请求超时，未自动重试") }
    private func fail(_ message: String) { state = .failed; error = message }
}
