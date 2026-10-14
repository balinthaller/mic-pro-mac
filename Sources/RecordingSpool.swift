import Foundation

private let oggTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)<<24
    for _ in 0..<8 { crc = crc & 0x80000000 == 0 ? crc << 1 : (crc << 1)^0x04C11DB7 }
    return crc
}
private let x25Table: [UInt16] = (0..<256).map { value in
    var crc = UInt16(value)
    for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1)^0x8408 }
    return crc
}
struct OggFileValidation { let pages: Int;let crc16: UInt16 }
func validateOggFile(at url: URL) throws -> OggFileValidation {
    let h = try FileHandle(forReadingFrom:url);defer{try? h.close()}
    var pages = 0;var flags: UInt8 = 0;var whole: UInt16 = 0xFFFF
    while let head = try h.read(upToCount:27),!head.isEmpty {
        guard head.count == 27,head.prefix(4) == Data("OggS".utf8),head[4] == 0 else { throw ProtocolError.invalidSettings }
        let count = Int(head[26]);let laces = count == 0 ? Data() : (try h.read(upToCount:count) ?? Data());guard laces.count == count else { throw ProtocolError.invalidSettings }
        let size = laces.reduce(0){$0+Int($1)};let payload = size == 0 ? Data() : (try h.read(upToCount:size) ?? Data());guard payload.count == size else { throw ProtocolError.invalidSettings }
        let page = head + laces + payload;var crc: UInt32 = 0
        for (index,byte) in page.enumerated() {
            whole = (whole >> 8)^x25Table[Int((whole^UInt16(byte))&255)]
            let value: UInt8 = (22..<26).contains(index) ? 0 : byte
            crc = (crc << 8)^oggTable[Int((crc >> 24)^UInt32(value))]
        }
        guard crc == little32(head,22) else { throw ProtocolError.invalidSettings }
        flags=head[5];pages+=1
    }
    guard pages > 0,flags&4 != 0 else { throw ProtocolError.invalidSettings }
    return OggFileValidation(pages:pages,crc16:whole^0xFFFF)
}

/// A bitmap bounds packet tracking; payload bytes live in a private disk spool.
final class RecordingSpool {
    private(set) var url: URL
    private var handle: FileHandle?
    private var bits = [UInt8]()
    private var total = 0;private var block = 0;private var count = 0
    private(set) var received = 0
    private(set) var packets = 0
    private(set) var contiguous = 0
    private var published = false
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("micpro-"+UUID().uuidString+".partial")
        guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw ProtocolError.invalidSettings }
        handle = try FileHandle(forUpdating:url)
    }
    deinit { discard() }
    func configure(total: Int,block: Int,count: Int) throws {
        if !bits.isEmpty { guard self.total == total,self.block == block,self.count == count else { throw ProtocolError.invalidSettings };return }
        self.total=total;self.block=block;self.count=count;bits=Array(repeating:0,count:(count+7)/8)
    }
    private func has(_ seq: Int) -> Bool { seq < count && bits[seq/8] & (1 << (seq%8)) != 0 }
    func put(_ seq: Int,_ data: Data) throws {
        guard seq >= 0,seq < count,let h = handle,data.count == (seq == count-1 ? total-seq*block : block) else { throw ProtocolError.invalidSettings }
        try h.seek(toOffset:UInt64(seq*block))
        if has(seq) { guard try h.read(upToCount:data.count) == data else { throw ProtocolError.invalidSettings };return }
        try h.write(contentsOf:data);bits[seq/8] |= 1 << (seq%8);received+=data.count;packets+=1
        while contiguous < count && has(contiguous) { contiguous+=1 }
    }
    var complete: Bool { count > 0 && packets == count && received == total }
    func validate() throws -> OggFileValidation { guard complete else { throw ProtocolError.invalidSettings };return try validateOggFile(at:url) }
    func publish(to target: URL) throws {
        try handle?.close();handle=nil
        try FileManager.default.moveItem(at:url,to:target);url=target;published=true
    }
    func discard() { try? handle?.close();handle=nil;if !published { try? FileManager.default.removeItem(at:url) } }
}
