import Foundation

struct DeviceTarget {
    let address: String
    let serialSuffix: String
    static func parse(_ object: [String:Any]) -> DeviceTarget? {
        guard let rawAddress=object["bluetooth_address"] as? String,
              let rawSuffix=object["serial_suffix"] as? String else { return nil }
        let address=rawAddress.uppercased().replacingOccurrences(of:"-",with:":")
        let suffix=rawSuffix.uppercased()
        guard address.range(of:"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$",options:.regularExpression) != nil,
              address != "00:00:00:00:00:00", address != "FF:FF:FF:FF:FF:FF",
              suffix.range(of:"^[A-Z0-9]{6}$",options:.regularExpression) != nil else { return nil }
        return DeviceTarget(address:address,serialSuffix:suffix)
    }
}

enum DeviceConfig {
    static let dataDirectory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MicProMac",isDirectory:true)
    static let configURL=ProcessInfo.processInfo.environment["MICPRO_CONFIG"].map {URL(fileURLWithPath:$0)} ?? dataDirectory.appendingPathComponent("config.json")
    private static let object: [String:Any] = {
        guard let data=try? Data(contentsOf:configURL), data.count <= 4096,
              let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return [:] }
        return value
    }()
    static let target=DeviceTarget.parse(object)
    // A missing configuration never becomes a broad name/identity match.
    static let serialSuffix=target?.serialSuffix ?? "UNCONFIGURED"
    static let address=target?.address ?? "UNCONFIGURED"
    static let experimentalFeaturesEnabled=object["experimental_features_enabled"] as? Bool == true
    static let codexQuotaEnabled=object["codex_quota_enabled"] as? Bool == true
}
