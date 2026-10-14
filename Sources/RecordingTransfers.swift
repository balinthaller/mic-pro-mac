import Foundation
import CryptoKit

struct RecordingTransferProgress {
    let received: Int
    let total: Int
    let started: Date
    let phase: String
    func json(now: Date = Date()) -> [String:Any] {
        let elapsed = max(0.001,now.timeIntervalSince(started))
        let speed = received > 0 ? Double(received)/elapsed : 0
        return ["received_bytes":received,"total_bytes":total,"progress_fraction":total > 0 ? min(1,Double(received)/Double(total)) : 0,
                "speed_bytes_per_second":speed,"eta_seconds":speed > 0 ? Double(max(0,total-received))/speed : NSNull(),"phase":phase]
    }
}

struct USBRecordingStore {
    let root: URL
    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:self.root.path,isDirectory:&directory),directory.boolValue else { throw TransferError.invalidRoot }
        let children = try FileManager.default.contentsOfDirectory(at:self.root,includingPropertiesForKeys:nil)
        guard children.contains(where:{$0.lastPathComponent == "AIRecord" || ($0.lastPathComponent.hasPrefix("audio_") && $0.pathExtension.lowercased() == "wav")}) else { throw TransferError.invalidRoot }
    }
    static func mounted() -> [USBRecordingStore] {
        ((try? FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:"/Volumes"),includingPropertiesForKeys:nil)) ?? []).compactMap { try? USBRecordingStore(root:$0) }
    }
    func file(_ relative: String) throws -> URL {
        guard !relative.isEmpty,!relative.hasPrefix("/"),!relative.split(separator:"/").contains("..") else { throw TransferError.invalidPath }
        let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"),["ogg","wav"].contains(url.pathExtension.lowercased()),
              (try url.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile == true else { throw TransferError.invalidPath }
        return url
    }
    func inventory() throws -> [[String:Any]] {
        var files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.pathExtension.lowercased() == "wav"}
        let ai = root.appendingPathComponent("AIRecord")
        if let e = FileManager.default.enumerator(at:ai,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) {
            while let url = e.nextObject() as? URL { if url.pathExtension.lowercased() == "ogg" { files.append(url) } }
        }
        return try files.sorted{$0.lastPathComponent > $1.lastPathComponent}.map { url in
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(root.path + "/") else { throw TransferError.invalidPath }
            let relative = String(canonical.path.dropFirst(root.path.count+1));let safe = try file(relative)
            let values = try safe.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            var item: [String:Any] = ["name":safe.lastPathComponent,"file_bytes":values.fileSize ?? 0,"format":safe.pathExtension.uppercased(),"transport":"usb","relative_path":relative,"usb_root":root.path]
            if let seconds = waveDuration(safe) { item["duration_seconds"] = seconds }
            return item
        }
    }
}
enum TransferError: LocalizedError {
    case invalidRoot, invalidPath, cancelled, sourceChanged, hashMismatch
    var errorDescription: String? {
        switch self {
        case .invalidRoot:return "未找到 Mic Pro 录音盘，请连接发射器或选择录音盘。"
        case .invalidPath:return "文件路径无效或超出所选录音盘。"
        case .cancelled:return "已取消，原录音保留。"
        case .sourceChanged:return "复制期间源文件发生变化，请停止内录后重新复制。"
        case .hashMismatch:return "复制文件的完整校验不匹配。"
        }
    }
}
func waveDuration(_ url: URL) -> Double? {
    guard url.pathExtension.lowercased() == "wav",let h = try? FileHandle(forReadingFrom:url) else { return nil }
    defer {try? h.close()}
    guard let header = try? h.read(upToCount:12),header.count == 12,Data(header.prefix(4)) == Data("RIFF".utf8),Data(header.suffix(4)) == Data("WAVE".utf8) else { return nil }
    var rate: UInt32 = 0;var offset: UInt64 = 12
    for _ in 0..<64 {
        guard (try? h.seek(toOffset:offset)) != nil,let chunk = try? h.read(upToCount:8),chunk.count == 8 else { return nil }
        let size = little32(chunk,4)
        if chunk.prefix(4) == Data("fmt ".utf8) {
            guard size >= 16,let fmt = try? h.read(upToCount:16),fmt.count == 16 else { return nil };rate = little32(fmt,8)
        } else if chunk.prefix(4) == Data("data".utf8) { return rate > 0 ? Double(size)/Double(rate) : nil }
        offset += 8 + UInt64(size) + UInt64(size & 1)
    }
    return nil
}

final class USBRecordingTransfer {
    let id: String
    let store: USBRecordingStore
    let relative: String
    let destination: URL
    private let lock = NSLock()
    private var cancelled = false
    private var running = true
    private var value = RecordingTransferProgress(received:0,total:0,started:Date(),phase:"准备复制")
    var onProgress: (() -> Void)?
    init(id: String,store: USBRecordingStore,relative: String,destination: URL) { self.id=id;self.store=store;self.relative=relative;self.destination=destination }
    var isRunning: Bool { lock.lock();defer{lock.unlock()};return running }
    var snapshot: [String:Any] { lock.lock();defer{lock.unlock()};return value.json().merging(["request_id":id,"transport":"usb","can_cancel":running]){a,_ in a} }
    func cancel() { lock.lock();cancelled=true;lock.unlock() }
    private func check() throws { lock.lock();defer{lock.unlock()};if cancelled { throw TransferError.cancelled } }
    private func update(_ received: Int,_ total: Int,_ phase: String) { lock.lock();value=RecordingTransferProgress(received:received,total:total,started:value.started,phase:phase);lock.unlock();onProgress?() }
    func run() -> [String:Any] {
        let folder = destination.appendingPathComponent(id)
        let partial = folder.appendingPathComponent("download.partial")
        defer {try? FileManager.default.removeItem(at:partial);lock.lock();running=false;lock.unlock()}
        do {
            try check()
            let source = try store.file(relative)
            let before = try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            guard let total = before.fileSize,total > 0 else { throw TransferError.sourceChanged }
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            guard FileManager.default.createFile(atPath:partial.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw TransferError.invalidPath }
            let input = try FileHandle(forReadingFrom:source);defer{try? input.close()}
            let output = try FileHandle(forWritingTo:partial);defer{try? output.close()}
            var hash = SHA256();var received = 0
            update(0,total,"有线复制")
            while received < total {
                try check()
                guard let data = try input.read(upToCount:min(512*1024,total-received)),!data.isEmpty else { throw TransferError.sourceChanged }
                try output.write(contentsOf:data);hash.update(data:data);received+=data.count;update(received,total,"有线复制")
            }
            try output.close();try check()
            let after = try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            guard before.fileSize == after.fileSize,before.contentModificationDate == after.contentModificationDate else { throw TransferError.sourceChanged }
            update(received,total,"校验文件")
            let verify = try FileHandle(forReadingFrom:partial);defer{try? verify.close()};var copiedHash = SHA256()
            while let data = try verify.read(upToCount:512*1024),!data.isEmpty { try check();copiedHash.update(data:data) }
            let digest = hash.finalize();guard digest == copiedHash.finalize() else { throw TransferError.hashMismatch }
            try check();let target = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at:partial,to:target)
            update(received,total,"完成")
            return ["ok":true,"action":"recordings-download","transport":"usb","request_id":id,"file":target.path,"bytes":total,"sha256":digest.map{String(format:"%02x",$0)}.joined(),"integrity":"source_stream_sha256+destination_sha256+size+source_snapshot","read_only":true,"elapsed_seconds":Date().timeIntervalSince(value.started)]
        } catch { return ["ok":false,"action":"recordings-download","transport":"usb","request_id":id,"error":error.localizedDescription,"cancelled":(error as? TransferError) == .cancelled] }
    }
}
