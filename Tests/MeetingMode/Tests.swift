import Foundation

@main struct PortableMeetingModeTests {
    static var groups = 0
    static let identity = padded("Insta360 TRC TX") + padded("TEST01")
    static func padded(_ value: String) -> Data { var data = Data(value.utf8); data.append(Data(repeating:0,count:16-data.count)); return data }
    static func request(_ plan: PortableMeetingModePlan) -> Frame {
        guard let bytes = plan.nextRequest() else { fatalError("Expected request in \(plan.state): \(plan.error ?? "none")") }
        var stream = FrameStream(); return stream.append(bytes)[0]
    }
    static func reply(_ request: Frame, _ body: Data, idOffset: UInt8 = 0) -> Frame {
        var id = Data(request.payload.prefix(2)); id[0] &+= idOffset
        return Frame(command:request.command,sequence:0,payload:id + Data([0]) + body)
    }
    static func values(_ group: UInt16, _ data: Data) -> Data {
        identity + Data([UInt8(group & 255),UInt8(group >> 8)]) + data + Data([0,0,0])
    }
    static func baseline(common: Data = Data(repeating:0,count:6), attributes: Data = Data(repeating:0,count:18), more: Data = Data(repeating:0,count:12)) -> PortableMeetingModePlan {
        let plan = PortableMeetingModePlan()
        assert(!plan.authorizeModeRequest())
        plan.consume(reply(request(plan),Data([1])+identity+Data([0])))
        plan.consume(reply(request(plan),identity+Data([0])))
        plan.consume(reply(request(plan),values(0x1000,common)))
        if plan.state == .failed { return plan }
        plan.consume(reply(request(plan),values(0x1012,more)))
        if plan.state == .failed { return plan }
        plan.consume(reply(request(plan),values(0x1017,attributes)))
        return plan
    }
    static func authorizedAndFresh(_ plan: PortableMeetingModePlan) {
        assert(plan.authorizeModeRequest())
        plan.consume(reply(request(plan),values(0x1000,Data(repeating:0,count:6))))
        plan.consume(reply(request(plan),values(0x1012,Data(repeating:0,count:12))))
        plan.consume(reply(request(plan),values(0x1017,Data(repeating:0,count:18))))
        assert(plan.state == .requestingMode && !plan.modeRequestWritten)
    }
    static func modeReply(_ plan: PortableMeetingModePlan) {
        authorizedAndFresh(plan)
        let req = request(plan)
        assert(req.command == 0x1020 && req.payload.count == 2)
        assert(plan.nextRequest() == nil)
        let body = identity.prefix(16) + padded("2.0.2.4") + identity.suffix(16) + Data([0])
        plan.consume(reply(req,body,idOffset:1),now:10)
        assert(!plan.modeReplyReceived && plan.state == .requestingMode)
        plan.consume(reply(req,body),now:10)
        assert(plan.modeReplyReceived && plan.state == .settling)
        assert(plan.nextRequest() == nil && !plan.settle(now:10.74))
        assert(plan.settle(now:10.75))
    }
    static func check(_ name: String, _ work: () -> Void) { work(); groups += 1; print("PASS \(name)") }
    static func main() {
        check("Inner identity progress drives harness; unrelated IDs do not") {
            let p = PortableMeetingModePlan(); let req = request(p)
            p.consume(reply(req,Data([1])+identity+Data([0]),idOffset:1))
            assert(p.responses == 0 && p.nextRequest() == nil)
            p.consume(reply(req,Data([1])+identity+Data([0])))
            assert(p.responses == 1 && p.state == .readingBaseline)
            assert(request(p).command == 0x100d)
        }
        check("Explicit gate and metadata is not completed mode") {
            let plan = baseline(); assert(plan.state == .baselineReady && plan.nextRequest() == nil)
            modeReply(plan)
            plan.consume(reply(request(plan),values(0x1000,Data(repeating:0,count:6))))
            plan.consume(reply(request(plan),values(0x1012,Data(repeating:0,count:12))))
            plan.consume(reply(request(plan),values(0x1017,Data(repeating:0,count:18))))
            assert(plan.state == .readyToDisconnect && !plan.authorizeModeRequest() && plan.nextRequest() == nil)
        }
        check("Refuse active/paused recording and auto-delete") {
            for index in [3,5,6] { var data = Data(repeating:0,count:18); data[index] = 1; let p = baseline(attributes:data); assert(p.state == .failed && !p.authorizeModeRequest()) }
            var common = Data(repeating:0,count:6); common[0] = 1
            assert(baseline(common:common).state == .failed)
        }
        check("Protected attribute changes fail closed") {
            for index in [2,3,4] {
                let p = baseline(); modeReply(p)
                p.consume(reply(request(p),values(0x1000,Data(repeating:0,count:6))))
                p.consume(reply(request(p),values(0x1012,Data(repeating:0,count:12))))
                var attributes = Data(repeating:0,count:18); attributes[index] = 1
                p.consume(reply(request(p),values(0x1017,attributes)))
                assert(p.state == .failed && p.nextRequest() == nil)
            }
        }
        check("Protected More changes fail closed") {
            for index in [8,9,10] {
                let p = baseline(); modeReply(p)
                p.consume(reply(request(p),values(0x1000,Data(repeating:0,count:6))))
                var more = Data(repeating:0,count:12); more[index] = 1
                p.consume(reply(request(p),values(0x1012,more)))
                assert(p.state == .failed)
            }
        }
        check("One-shot timeout never resends mode") {
            let p = baseline(); authorizedAndFresh(p); _ = request(p); p.timeout()
            assert(p.state == .failed && p.modeRequestWritten && !p.modeReplyReceived && p.nextRequest() == nil && !p.authorizeModeRequest())
        }
        check("Malformed attributes and wrong serial fail closed") {
            let p = baseline(); modeReply(p)
            p.consume(reply(request(p),values(0x1000,Data(repeating:0,count:6))))
            p.consume(reply(request(p),values(0x1012,Data(repeating:0,count:12))))
            var body = values(0x1017,Data(repeating:0,count:18)); body[54] = 1
            p.consume(reply(request(p),body)); assert(p.state == .failed)
            let q = baseline(); authorizedAndFresh(q); let req = request(q)
            q.consume(reply(req,identity.prefix(16)+padded("2.0.2.4")+padded("WRONG")+Data([0])))
            assert(q.state == .failed && !q.modeReplyReceived)
            let t = baseline(); authorizedAndFresh(t); let typeReq = request(t)
            t.consume(reply(typeReq,padded("OTHER TX")+padded("2.0.2.4")+identity.suffix(16)+Data([0])))
            assert(t.state == .failed && !t.modeReplyReceived)
        }
        check("Rejected mode request cannot be retried") {
            let p = baseline(); authorizedAndFresh(p); let req = request(p)
            p.consume(Frame(command:req.command,sequence:0,payload:Data(req.payload.prefix(2))+Data([1])))
            assert(p.state == .failed && !p.modeReplyReceived && p.nextRequest() == nil && !p.authorizeModeRequest())
        }
        check("Fresh gate refuses intervening recording before any mode request") {
            for index in [0, 5, 6] {
                let p = baseline(); assert(p.authorizeModeRequest())
                var common = Data(repeating:0,count:6); if index == 0 { common[0] = 1 }
                p.consume(reply(request(p),values(0x1000,common)))
                if index != 0 {
                    p.consume(reply(request(p),values(0x1012,Data(repeating:0,count:12))))
                    var attrs = Data(repeating:0,count:18); attrs[index] = 1
                    p.consume(reply(request(p),values(0x1017,attrs)))
                }
                assert(p.state == .failed && !p.modeRequestWritten && p.nextRequest() == nil)
            }
        }
        check("Fresh gate protection changes refuse before mode emission") {
            for index in [2, 3, 4] {
                let p = baseline(); assert(p.authorizeModeRequest())
                p.consume(reply(request(p),values(0x1000,Data(repeating:0,count:6))))
                p.consume(reply(request(p),values(0x1012,Data(repeating:0,count:12))))
                var attrs = Data(repeating:0,count:18); attrs[index] = 1
                p.consume(reply(request(p),values(0x1017,attrs)))
                assert(p.state == .failed && !p.modeRequestWritten)
            }
            for index in [2, 8, 9, 10] {
                let p = baseline(); assert(p.authorizeModeRequest())
                p.consume(reply(request(p),values(0x1000,Data(repeating:0,count:6))))
                var more = Data(repeating:0,count:12); more[index] = 1
                p.consume(reply(request(p),values(0x1012,more)))
                assert(p.state == .failed && !p.modeRequestWritten)
            }
        }
        check("Initial loop and child lock refuse without altering baseline") {
            var attrs = Data(repeating:0,count:18); attrs[2] = 1
            assert(baseline(attributes:attrs).state == .failed)
            for index in [2, 8] { var more = Data(repeating:0,count:12); more[index] = 1; assert(baseline(more:more).state == .failed) }
            let p = baseline(); let before = p.baselineAttributes; authorizedAndFresh(p)
            assert(p.baselineAttributes == before && p.gateAttributes == before)
        }
        check("Auto-record refuses initial and fresh gate without mutation") {
            var more = Data(repeating:0,count:12); more[7] = 1
            let initial = baseline(more:more)
            assert(initial.state == .failed && !initial.modeRequestWritten && !initial.authorizeModeRequest())
            let p = baseline(); assert(p.authorizeModeRequest())
            p.consume(reply(request(p),values(0x1000,Data(repeating:0,count:6))))
            p.consume(reply(request(p),values(0x1012,more)))
            assert(p.state == .failed && !p.modeRequestWritten && p.nextRequest() == nil)
        }
        print("\(groups) MeetingMode test groups passed")
    }
}
