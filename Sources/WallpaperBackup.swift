import AppKit
import CryptoKit

private func pngCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
    }
    return crc ^ 0xFFFFFFFF
}
private func big32(_ d: Data, _ at: Int) -> Int { Int(d[at]) << 24 | Int(d[at+1]) << 16 | Int(d[at+2]) << 8 | Int(d[at+3]) }
func decodedWallpaperPanel(_ png: Data) throws -> Data {
    guard png.count <= 0x38000, png.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw ProtocolError.invalidSettings }
    var at = 8; var ended = false; var headers = 0
    while at + 12 <= png.count {
        let size = big32(png,at)
        guard size <= 0x38000, at + 12 + size <= png.count else { throw ProtocolError.invalidSettings }
        let type = String(decoding: png[(at+4)..<(at+8)], as: UTF8.self)
        let covered = Data(png[(at+4)..<(at+8+size)])
        guard UInt32(big32(png,at+8+size)) == pngCRC32(covered), type != "acTL" else { throw ProtocolError.invalidSettings }
        if type == "IHDR" {
            headers += 1
            guard at == 8, size == 13, big32(png,at+8) == 240, big32(png,at+12) == 240 else { throw ProtocolError.invalidSettings }
        }
        at += 12 + size
        if type == "IEND" { guard size == 0 else { throw ProtocolError.invalidSettings }; ended = true; break }
    }
    guard headers == 1, ended, at == png.count, let rep = NSBitmapImageRep(data: png), rep.pixelsWide == 240, rep.pixelsHigh == 240 else { throw ProtocolError.invalidSettings }
    let palette: [(Int,Int,Int,UInt8)] = [(30,30,30,0),(160,160,160,1),(160,160,0,2),(130,20,20,3),(0,80,150,5),(50,100,70,6)]
    var panel = Data(); var high: UInt8 = 0
    for y in 0..<240 { for x in 0..<240 {
        guard rep.bitsPerSample == 8, rep.samplesPerPixel == 3 || rep.samplesPerPixel == 4 else { throw ProtocolError.invalidSettings }
        var pixel = [Int](repeating:0,count:rep.samplesPerPixel); rep.getPixel(&pixel,atX:x,y:y)
        let alphaFirst = rep.hasAlpha && rep.bitmapFormat.contains(.alphaFirst)
        let offset = alphaFirst ? 1 : 0
        guard !rep.hasAlpha || pixel[alphaFirst ? 0 : 3] == 255 else { throw ProtocolError.invalidSettings }
        let rgb = (pixel[offset],pixel[offset+1],pixel[offset+2])
        guard let match = palette.first(where: { $0.0 == rgb.0 && $0.1 == rgb.1 && $0.2 == rgb.2 }) else { throw ProtocolError.invalidSettings }
        if y < 208 {
            if x % 2 == 0 { high = match.3 << 4 } else { panel.append(high | match.3) }
        }
    } }
    guard panel.count == 24960 else { throw ProtocolError.invalidSettings }
    return panel
}
func validatedWallpaperPanel(_ png: Data, inventory: Data, identity: Data) throws -> Data {
    guard inventory.count == 50, inventory[0] == 1, inventory[1..<33] == identity, inventory[33] == 1 else { throw ProtocolError.invalidSettings }
    let panel = try decodedWallpaperPanel(png)
    guard Data(Insecure.MD5.hash(data:panel)) == inventory.suffix(16) else { throw ProtocolError.invalidSettings }
    return panel
}
struct PreparedWallpaperUpload {
    let png: Data
    let panel: Data
    let backupPNG: Data
    let backupPanel: Data
    let expectedInventory: Data
    let backupDirectory: URL
}
func prepareWallpaperUpload(image: String, backup: String, readPlan: AppControlReadPlan) throws -> PreparedWallpaperUpload {
    let directory = URL(fileURLWithPath:backup)
    guard let raw = try? Data(contentsOf:directory.appendingPathComponent("manifest.json")),
          let info = try? JSONSerialization.jsonObject(with:raw) as? [String:Any],
          let identity = readPlan.identity, let inventory = readPlan.wallpaperInventory else { throw ProtocolError.invalidSettings }
    let originalPNG = try Data(contentsOf:directory.appendingPathComponent("original.png"))
    let originalPanel = try Data(contentsOf:directory.appendingPathComponent("original.panel"))
    func hash(_ d: Data) -> String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
    guard info["png_sha256"] as? String == hash(originalPNG), info["panel_sha256"] as? String == hash(originalPanel),
          info["identity_hex"] as? String == identity.map({String(format:"%02x",$0)}).joined(),
          try validatedWallpaperPanel(originalPNG,inventory:inventory,identity:identity) == originalPanel else { throw ProtocolError.invalidSettings }
    let png = try canonicalWallpaperPNG(path:image); let panel = try decodedWallpaperPanel(png)
    guard png.count <= 0x38000, Data(Insecure.MD5.hash(data:panel)) != inventory.suffix(16) else { throw ProtocolError.invalidSettings }
    let recovery: [String:Any] = ["prepared_at":ISO8601DateFormatter().string(from:Date()),"original_png_sha256":hash(originalPNG),"original_panel_sha256":hash(originalPanel),
        "proposed_png_sha256":hash(png),"proposed_panel_sha256":hash(panel),"restore_type2_bytes":24960,"restore_type3_bytes":originalPNG.count,
        "restore_type2_crc_x25":Int(wallpaperCRC(originalPanel)),"restore_type3_crc_x25":Int(wallpaperCRC(originalPNG)),
        "restore_protocol_offline_validated":true,"restore_on_hardware_verified":false,"method":"100A(identity+originalMD5), type2 bitmap then type3 PNG, ACK each10, CRC-X25, final GET1009 and readback; CANCEL is not rollback"]
    try JSONSerialization.data(withJSONObject:recovery,options:[.sortedKeys,.prettyPrinted]).write(to:directory.appendingPathComponent("restoration-plan.json"),options:.atomic)
    try png.write(to:directory.appendingPathComponent("proposed.png"),options:.atomic)
    try panel.write(to:directory.appendingPathComponent("proposed.panel"),options:.atomic)
    return PreparedWallpaperUpload(png:png,panel:panel,backupPNG:originalPNG,backupPanel:originalPanel,expectedInventory:inventory,backupDirectory:directory)
}
func saveWallpaperBackup(plan: WallpaperReadPlan, readPlan: AppControlReadPlan, id: String) throws -> URL {
    guard UUID(uuidString:id) != nil, let png = plan.file, let manifest = plan.manifest, let inventory = readPlan.wallpaperInventory, let identity = readPlan.identity else { throw ProtocolError.invalidSettings }
    let panel = try validatedWallpaperPanel(png,inventory:inventory,identity:identity)
    let directory = URL(fileURLWithPath:projectRoot + "/backups/" + id)
    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
    func hash(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    let metadata: [String:Any] = ["schema":1,"created_at":ISO8601DateFormatter().string(from:Date()),"identity_hex":identity.map { String(format:"%02x",$0) }.joined(),
        "inventory_hex":inventory.map { String(format:"%02x",$0) }.joined(),"manifest_hex":manifest.map { String(format:"%02x",$0) }.joined(),
        "png_sha256":hash(png),"panel_sha256":hash(panel),"wallpaper_md5":Insecure.MD5.hash(data:panel).map { String(format:"%02x",$0) }.joined(),
        "png_crc_and_inventory_md5_validated":true,"transport_crc_fields_absent":plan.missingCRC,"upload_restore_verified":false]
    try png.write(to:directory.appendingPathComponent("original.png"),options:.atomic)
    try panel.write(to:directory.appendingPathComponent("original.panel"),options:.atomic)
    try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys,.prettyPrinted]).write(to:directory.appendingPathComponent("manifest.json"),options:.atomic)
    return directory
}
func prepareWallpaperRestore(backup: String, readPlan: AppControlReadPlan) throws -> PreparedWallpaperUpload {
    let directory = URL(fileURLWithPath:backup)
    guard let info = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("manifest.json"))) as? [String:Any],
          let recovery = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("restoration-plan.json"))) as? [String:Any] else { throw ProtocolError.invalidSettings }
    let png = try Data(contentsOf:directory.appendingPathComponent("original.png"));let panel = try Data(contentsOf:directory.appendingPathComponent("original.panel"))
    let proposed = try Data(contentsOf:directory.appendingPathComponent("proposed.png"))
    guard let identity = readPlan.identity,let inventory = readPlan.wallpaperInventory,
          info["identity_hex"] as? String == identity.map({String(format:"%02x",$0)}).joined(),
          info["png_sha256"] as? String == SHA256.hash(data:png).map({String(format:"%02x",$0)}).joined(),
          info["panel_sha256"] as? String == SHA256.hash(data:panel).map({String(format:"%02x",$0)}).joined(),
          recovery["proposed_png_sha256"] as? String == SHA256.hash(data:proposed).map({String(format:"%02x",$0)}).joined(),
          try decodedWallpaperPanel(png) == panel else { throw ProtocolError.invalidSettings }
    guard inventory.count == 50, inventory[0] == 1, inventory[1..<33] == identity else { throw ProtocolError.invalidSettings }
    _ = try decodedWallpaperPanel(proposed)
    return PreparedWallpaperUpload(png:png,panel:panel,backupPNG:png,backupPanel:panel,expectedInventory:inventory,backupDirectory:directory)
}
/// Convert ordinary local PNG/JPEG into the panel's canonical six-color metadata.
func canonicalWallpaperPNG(path: String) throws -> Data {
    let url = URL(fileURLWithPath:path)
    guard ["png","jpg","jpeg"].contains(url.pathExtension.lowercased()),
          let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize, size <= 20_000_000 else { throw ProtocolError.invalidSettings }
    let source = try Data(contentsOf:url)
    if (try? decodedWallpaperPanel(source)) != nil { return source }
    let image = try loadWallpaperSource(url)
    return try renderedWallpaper(image:image,options:WallpaperRenderOptions())
}
