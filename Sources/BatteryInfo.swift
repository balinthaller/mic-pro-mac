import Foundation

/// TX 2.0.2.4 GET1005 body. The device leaves the 32 identity bytes zero;
/// accept that only within a query already bound to its verified channel identity.
struct BatteryInfo {
    let percent: Int
    let batteryType: UInt8
    let powerType: UInt8
    static func decode(_ body: Data, identity: Data) -> BatteryInfo? {
        guard identity.count == 32,
              String(decoding:identity.dropFirst(16).prefix(while:{$0 != 0}),as:UTF8.self).hasSuffix(DeviceConfig.serialSuffix),
              body.count == 36, (body.prefix(32) == identity || body.prefix(32).allSatisfy({$0 == 0})),
              body[32] <= 100, body[33] == 1, body[34] <= 1, body[35] == 0 else { return nil }
        return BatteryInfo(percent:Int(body[32]),batteryType:body[33],powerType:body[34])
    }
}
struct BatteryPowerReading {
    let info: BatteryInfo
    let at: Date
    func fresh(connected: Bool, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(at)
        return connected && age >= 0 && age <= 90
    }
    func label(connected: Bool, now: Date = Date()) -> String {
        guard fresh(connected:connected,now:now) else { return "充电状态未知" }
        return info.powerType == 0 ? "未充电" : info.percent >= 100 ? "已接电源" : "充电中"
    }
}
