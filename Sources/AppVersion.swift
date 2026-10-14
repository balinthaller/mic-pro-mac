import Foundation

enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0" }
    static var revision: String { Bundle.main.object(forInfoDictionaryKey:"MicProGitRevision") as? String ?? "unknown" }
    static var label: String { "v\(version) · \(revision)" }
}
