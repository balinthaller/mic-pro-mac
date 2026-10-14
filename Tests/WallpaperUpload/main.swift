import Foundation
let identity = Data(repeating:65,count:32)
let plan = try! WallpaperUploadPlan(identity:identity,panel:Data(repeating:0x11,count:24960),png:Data(repeating:1,count:3695))
var frames = FrameStream();var counts = [Int:Int]();var dataType = 2
for _ in 0..<100 {
    if plan.state == .ready { break }
    let requests = plan.requests();assert(!requests.isEmpty)
    let parsed = requests.flatMap { frames.append($0) }
    if parsed[0].command == 0x21 {
        for frame in parsed {
            let bytes = Data(frame.payload.dropFirst(8))
            assert(bytes.count == Int(little16(frame.payload,4)) && wallpaperCRC(bytes) == little16(frame.payload,6))
            counts[dataType,default:0] += bytes.count
        }
        assert(plan.requests().isEmpty)
        plan.consume(Frame(command:0x21,sequence:0,payload:parsed.last!.payload.prefix(4)+Data([0])))
    } else {
        let frame = parsed[0]
        if frame.command == 0x20 { dataType = Int(frame.payload[2]);assert(little32(frame.payload,3) == 0) }
        plan.consume(Frame(command:frame.command,sequence:0,payload:frame.payload.prefix(2)+Data([0])))
    }
}
assert(plan.state == .ready && counts[2] == 24960 && counts[3] == 3695)
let failed = try! WallpaperUploadPlan(identity:identity,panel:Data(repeating:0x11,count:24960),png:Data([1]))
_ = failed.requests();failed.timeout();assert(failed.requests().isEmpty && !failed.destructiveStarted)
print("PASS: panel then metadata, exact totals, per-chunk CRC, 10-packet ACK gate, no retries after uncertain response")
