import Foundation
let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
let source = root.appendingPathComponent("mic/AIRecord");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:root)}
let bytes = Data(repeating:71,count:1024*1024);try bytes.write(to:source.appendingPathComponent("test.ogg"))
let store = try USBRecordingStore(root:root.appendingPathComponent("mic"));let inventory = try store.inventory();assert(inventory.count == 1)
let worker = USBRecordingTransfer(id:UUID().uuidString,store:store,relative:"AIRecord/test.ogg",destination:root.appendingPathComponent("out"))
let r = worker.run();let copied = try Data(contentsOf:URL(fileURLWithPath:r["file"] as! String));assert(r["ok"] as? Bool == true && copied == bytes)
let cancelled = USBRecordingTransfer(id:UUID().uuidString,store:store,relative:"AIRecord/test.ogg",destination:root.appendingPathComponent("out"))
cancelled.onProgress = { if (cancelled.snapshot["received_bytes"] as? Int ?? 0) > 0 { cancelled.cancel() } }
assert(cancelled.run()["cancelled"] as? Bool == true)
let original = try Data(contentsOf:source.appendingPathComponent("test.ogg"));assert(original == bytes)
do { _ = try store.file("../test.ogg");assertionFailure() } catch { }
let outside = root.appendingPathComponent("outside.ogg");try bytes.write(to:outside)
try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("escape.ogg"),withDestinationURL:outside)
do { _ = try store.file("AIRecord/escape.ogg");assertionFailure() } catch { }
print("PASS USB inventory, streaming SHA-verified copy, mid-copy cancellation, source preservation and path/symlink confinement")
