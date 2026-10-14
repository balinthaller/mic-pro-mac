import Foundation
let workflow = ScreenUIWorkflow(id:UUID().uuidString,image:"/tmp/test.png")
assert(workflow.acceptBackup(["ok":false,"backup_directory":"/tmp/backup"]) == nil)
assert(workflow.acceptBackup(["ok":true]) == nil)
assert(workflow.acceptBackup(["ok":true,"backup_directory":""]) == nil)
assert(!workflow.uploading)
let before = workflow.id
assert(workflow.acceptBackup(["ok":true,"backup_directory":"/tmp/backup"]) == "/tmp/backup")
assert(workflow.uploading && workflow.id != before && UUID(uuidString:workflow.id) != nil)
assert(workflow.acceptBackup(["ok":true,"backup_directory":"/tmp/backup"]) == nil)
print("PASS: UI upload blocked on failed/missing backup; valid backup changes stage once with a new operation ID")
