import Foundation
func parse(_ json: String)->CodexQuotaSnapshot?{CodexQuotaSnapshot.parse(Data(json.utf8))}
let quota=parse(#"{"ok":true,"read_at":1000,"windows":[{"used_percent":10,"window_minutes":10080,"resets_at":5000}]}"#)!
assert(quota.summary=="90%" && quota.windows.count==1 && quota.windows[0].label=="周额度")
assert(quota.stale(now:Date(timeIntervalSince1970:900)))
assert(!quota.stale(now:Date(timeIntervalSince1970:1500)) && quota.stale(now:Date(timeIntervalSince1970:2000)))
assert(quota.detail(now:Date(timeIntervalSince1970:1500)).contains("第二额度窗口：未提供"))
assert(parse(#"{"ok":true,"read_at":1000,"windows":[]}"#)==nil)
assert(parse(#"{"ok":false,"read_at":1000,"windows":[{"used_percent":10,"window_minutes":10080,"resets_at":5000}]}"#)==nil)
assert(parse(#"{"ok":true,"read_at":1000,"windows":[{"used_percent":101,"window_minutes":10080,"resets_at":5000}]}"#)==nil)
let exhausted=parse(#"{"ok":true,"read_at":1000,"windows":[{"used_percent":100,"window_minutes":300,"resets_at":5000}]}"#)!
assert(exhausted.summary=="0%" && exhausted.windows[0].label=="5小时额度")
print("PASS quota remaining/used semantics, optional windows, stale/future timestamps, invalid payloads, exhaustion")
