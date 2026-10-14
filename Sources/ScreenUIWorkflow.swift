import Foundation

final class ScreenUIWorkflow {
    var id: String
    var uploading = false
    let image: String
    init(id: String,image: String) { self.id = id;self.image = image }
    func acceptBackup(_ payload: [String:Any]) -> String? {
        guard !uploading,payload["ok"] as? Bool == true, let backup = payload["backup_directory"] as? String,!backup.isEmpty else { return nil }
        uploading = true;id = UUID().uuidString;return backup
    }
}
