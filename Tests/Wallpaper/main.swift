import Foundation
assert(wallpaperCRC(Data("123456789".utf8)) == 0x906E)
let identity = Data(repeating:65,count:32)
func setup(_ plan: WallpaperReadPlan, file: Data, count: UInt32 = 2) {
    func reply(_ request: Data, _ body: Data) -> Frame {
        var stream = FrameStream(); let frame = stream.append(request)[0]
        return Frame(command:frame.command,sequence:0,payload:frame.payload.prefix(2)+Data([0])+body)
    }
    let selected = plan.nextRequest()!; var frames = FrameStream(); assert(frames.append(selected)[0].command == 0x100B)
    _ = plan.consume(reply(selected,Data()))
    let begin = plan.nextRequest()!
    let crc = wallpaperCRC(file)
    let manifest = Data([3])+encoded32(0)+encoded32(UInt32(file.count))+Data([UInt8(crc & 255),UInt8(crc >> 8),1,0])+encoded32(count)
    _ = plan.consume(reply(begin,manifest))
}
func chunk(_ sequence: UInt32, _ data: Data, valid: Bool = true) -> Frame {
    let crc = wallpaperCRC(data) ^ (valid ? 0 : 1)
    return Frame(command:0x31,sequence:0,payload:encoded32(sequence)+Data([UInt8(data.count),0,UInt8(crc & 255),UInt8(crc >> 8)])+data)
}
let bytes = Data([1,2,3,4]);let plan = WallpaperReadPlan(identity:identity);setup(plan,file:bytes)
_ = plan.consume(chunk(1,Data([3,4])));assert(plan.state == .receiving)
assert(plan.consume(chunk(0,Data([1,2]))) != nil && plan.state == .ready && plan.file == bytes)
let corrupt = WallpaperReadPlan(identity:identity);setup(corrupt,file:bytes)
_ = corrupt.consume(chunk(0,Data([1,2]),valid:false));assert(corrupt.state == .failed && corrupt.file == nil)
let duplicate = WallpaperReadPlan(identity:identity);setup(duplicate,file:bytes)
_ = duplicate.consume(chunk(0,Data([1,2])));_ = duplicate.consume(chunk(0,Data([2,1])))
assert(duplicate.state == .failed)
let timed = WallpaperReadPlan(identity:identity);_ = timed.nextRequest();timed.timeout();assert(timed.nextRequest() == nil)
print("PASS: CRC-X25 vector, read-only selection/manifest, out-of-order completion, corrupt/conflicting chunk rejection, timeout without writes")
