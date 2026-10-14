import Foundation

struct DiscoveryAdvertisement {
    let identifier: UUID
    let localName: String?
    let peripheralName: String?
    let services: [String]
    let manufacturer: Data?
    let connectable: Bool?
    let rssi: Int
}
struct DiscoveryObservationModel {
    let verifiedIdentifier: UUID?
    let startedAt: Date
    private(set) var otherAdvertisementCount = 0
    private(set) var targetAdvertisementCount = 0
    private(set) var unverifiedServiceCandidateCount = 0
    private(set) var systemEnumerationAt: Date?
    private(set) var systemConnectedTargetCount = 0
    private(set) var systemConnectedTargetStates = [String]()
    private(set) var rows = [[String: Any]]()
    static let duration: TimeInterval = 60
    static let maximumRows = 512
    static let verifiedServiceUUID = "e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1"
    func matches(identifier: UUID, name: String?) -> Bool {
        identifier == verifiedIdentifier || name?.contains(DeviceConfig.serialSuffix) == true
    }
    func matches(_ advertisement: DiscoveryAdvertisement) -> Bool {
        advertisement.identifier == verifiedIdentifier ||
        advertisement.localName?.contains(DeviceConfig.serialSuffix) == true ||
        advertisement.peripheralName?.contains(DeviceConfig.serialSuffix) == true
    }
    mutating func observe(_ advertisement: DiscoveryAdvertisement, at time: Date) {
        guard time >= startedAt, time.timeIntervalSince(startedAt) < Self.duration else { return }
        guard matches(advertisement) else {
            otherAdvertisementCount += 1
            if advertisement.services.contains(where: { $0.caseInsensitiveCompare(Self.verifiedServiceUUID) == .orderedSame }) {
                unverifiedServiceCandidateCount += 1
            }
            return
        }
        targetAdvertisementCount += 1
        guard rows.count < Self.maximumRows else { return }
        let manufacturer = advertisement.manufacturer
        rows.append([
            "observed_at": ISO8601DateFormatter().string(from:time),
            "matched_by": advertisement.identifier == verifiedIdentifier ? "verified_uuid" :
                (advertisement.localName?.contains(DeviceConfig.serialSuffix) == true ? "advertised_local_name" : "cached_peripheral_name"),
            "local_name": advertisement.localName.map { String($0.prefix(256)) } as Any? ?? NSNull(),
            "service_uuids": Array(advertisement.services.prefix(32)),
            "manufacturer_hex": manufacturer.map { $0.prefix(512).map { String(format:"%02x",$0) }.joined() } as Any? ?? NSNull(),
            "manufacturer_bytes": manufacturer?.count as Any? ?? NSNull(),
            "is_connectable": advertisement.connectable as Any? ?? NSNull(),
            "rssi": advertisement.rssi
        ])
    }
    /// Snapshot from the OS service-filtered connected-peripheral enumeration;
    /// it neither initiates a connection nor establishes which application owns it.
    mutating func observeSystemConnected(_ peripherals: [(identifier:UUID,name:String?,state:String)], at time:Date) {
        guard systemEnumerationAt == nil, time >= startedAt, time.timeIntervalSince(startedAt) < Self.duration else { return }
        systemEnumerationAt=time
        var seen=Set<UUID>()
        for peripheral in peripherals where matches(identifier:peripheral.identifier,name:peripheral.name) {
            guard seen.insert(peripheral.identifier).inserted else { continue }
            systemConnectedTargetCount += 1
            if systemConnectedTargetStates.count < 32 {
                systemConnectedTargetStates.append(["disconnected","connecting","connected","disconnecting"].contains(peripheral.state) ? peripheral.state : "unknown")
            }
        }
    }
    func report(endedAt: Date, reason: String) -> [String: Any] {
        ["schema":1,"mode":"read_only_ble_observation", "started_at":ISO8601DateFormatter().string(from:startedAt),
         "ended_at":ISO8601DateFormatter().string(from:endedAt),"stop_reason":reason,
         "elapsed_seconds":max(0,endedAt.timeIntervalSince(startedAt)),
         "target_advertisement_count":targetAdvertisementCount,"other_advertisement_count":otherAdvertisementCount,
         "unverified_service_candidate_advertisement_count":unverifiedServiceCandidateCount,
         "system_connected_observation_basis":"OS service-filtered enumeration only; does not prove phone connectivity or device advertising",
         "system_connected_enumeration_performed":systemEnumerationAt != nil,
         "system_connected_observed_at":systemEnumerationAt.map { ISO8601DateFormatter().string(from:$0) } as Any? ?? NSNull(),
         "system_connected_target_count":systemEnumerationAt == nil ? NSNull() : systemConnectedTargetCount as Any,
         "system_connected_target_states":systemConnectedTargetStates,
         "recorded_target_rows":rows.count,"target_rows_truncated":targetAdvertisementCount > rows.count,"advertisements":rows,
         "limitations":["Matching name alone does not prove Insta360 or Tencent app compatible advertising; cached peripheral names may not be in this advertisement.",
                         "No observed target does not prove that the device did not advertise.",
                         "An exact service UUID with an unverified identity is counted as a candidate only, never as a target.",
                         "Other device identities are neither recorded nor persisted; their advertisement callbacks are counted only."],
         "connections_initiated":false,"characteristics_read":false,"packets_written":false]
    }
}
