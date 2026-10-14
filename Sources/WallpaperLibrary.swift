import AppKit
import CryptoKit

struct WallpaperAsset: Codable {
    var id: String
    var title: String
    var origin: String
    var styles: [String]
    var states: [String]
    var topics: [String]
    var path: String
    var quadrant: Int?
    var digest: String?
    var favorite=false
    var tags: [String] {styles+states+topics}
    var originLabel: String {origin == "official" ? "官方参考 · 截图裁片" : origin == "design" ? "原创设计" : "自定义"}
}
struct WallpaperAssetEdit: Codable {
    var title: String
    var styles: [String]
    var states: [String]
    var topics: [String]
    var favorite: Bool
}
struct WallpaperLibrarySaved: Codable {
    var custom=[WallpaperAsset]()
    var edits=[String:WallpaperAssetEdit]()
}
struct WallpaperFilter {
    var query="",origin="",style="",state="",topic="",favorites=false
    func matches(_ asset: WallpaperAsset)->Bool {
        (origin.isEmpty || asset.origin==origin) && (style.isEmpty || asset.styles.contains(style)) && (state.isEmpty || asset.states.contains(state)) && (topic.isEmpty || asset.topics.contains(topic)) && (!favorites || asset.favorite) && (query.isEmpty || ([asset.title,asset.originLabel]+asset.tags).joined(separator:" ").localizedCaseInsensitiveContains(query))
    }
}
final class WallpaperLibrary {
    let root: URL,storage: URL
    private(set) var assets=[WallpaperAsset]()
    private(set) var storageError: String?
    private var saved=WallpaperLibrarySaved(),images=[String:NSImage]()
    init(root: URL,storage: URL?=nil){
        self.root=root;self.storage=storage ?? root.appendingPathComponent("logs/wallpaper-library/managed")
        let index=self.storage.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath:index.path) {do{saved=try JSONDecoder().decode(WallpaperLibrarySaved.self,from:Data(contentsOf:index))}catch{storageError="素材库索引无法读取；保留原文件，暂不保存修改。"}}
        load()
    }
    private func load(){
        let tiles=root.appendingPathComponent("logs/wallpaper-library/tiles")
        if let data=try? Data(contentsOf:tiles.appendingPathComponent("manifest.json")),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let items=object["items"] as? [[String:Any]] {
            for item in items {
                guard let id=item["id"] as? String,id.range(of:"^IMG_[0-9]{4}-c[12]-r[0-9]{2}$",options:.regularExpression) != nil,let category=item["category"] as? String else{continue}
                let style=category=="标签" ? "大字标签" : category=="腾讯会议" ? "文字贴纸" : category
                assets.append(WallpaperAsset(id:id,title:category+" · "+id.replacingOccurrences(of:"IMG_",with:""),origin:"official",styles:[style],states:[],topics:[category],path:tiles.appendingPathComponent(id+".png").path))
            }
        }
        let states=["专注","等待确认","完成","出错"]
        for (name,style) in [("bauhaus","包豪斯"),("swiss","瑞士"),("apple","苹果启发")] {
            let path=root.appendingPathComponent("web/design/state-assets/"+name+(name=="swiss" ? ".svg" : ".png")).path
            guard FileManager.default.fileExists(atPath:path) else { continue }
            for i in 0..<4 {assets.append(WallpaperAsset(id:"design-"+name+"-\(i)",title:style+" · "+states[i],origin:"design",styles:[style],states:[states[i]],topics:["Agent状态"],path:path,quadrant:i))}
        }
        assets+=saved.custom.filter{$0.origin=="custom" && URL(fileURLWithPath:$0.path).deletingLastPathComponent().standardizedFileURL==storage.standardizedFileURL}
        for i in assets.indices {if let edit=saved.edits[assets[i].id]{assets[i].title=edit.title;assets[i].styles=edit.styles;assets[i].states=edit.states;assets[i].topics=edit.topics;assets[i].favorite=edit.favorite}}
    }
    func filtered(_ filter: WallpaperFilter)->[WallpaperAsset]{
        let order=["design":0,"custom":1,"official":2]
        return assets.filter{filter.matches($0)}.sorted{
            if $0.favorite != $1.favorite{return $0.favorite}
            if $0.origin != $1.origin{return (order[$0.origin] ?? 3)<(order[$1.origin] ?? 3)}
            if $0.origin=="design" {
                let a=$0.styles.first ?? "",b=$1.styles.first ?? ""
                if a != b{return a.localizedStandardCompare(b) == .orderedAscending}
                if let a=$0.quadrant,let b=$1.quadrant,a != b{return a<b}
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    func values(_ key: KeyPath<WallpaperAsset,[String]>)->[String]{Array(Set(assets.flatMap{$0[keyPath:key]})).sorted()}
    private func persist(_ value: WallpaperLibrarySaved) throws {
        guard storageError==nil else{throw CocoaError(.fileReadCorruptFile)}
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONEncoder().encode(value),url=storage.appendingPathComponent("library.json")
        try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func edit(id: String,title: String,styles:[String],states:[String],topics:[String],favorite: Bool) throws {
        guard let index=assets.firstIndex(where:{$0.id==id}),!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw CocoaError(.fileReadInvalidFileName)}
        var next=saved;next.edits[id]=WallpaperAssetEdit(title:title,styles:styles,states:states,topics:topics,favorite:favorite);try persist(next);saved=next
        assets[index].title=title;assets[index].styles=styles;assets[index].states=states;assets[index].topics=topics;assets[index].favorite=favorite
    }
    func importImage(_ url: URL) throws -> WallpaperAsset {
        guard storageError==nil else{throw CocoaError(.fileReadCorruptFile)}
        let source=try loadWallpaperSource(url);guard source.size.width>0,source.size.height>0,source.size.width<=8192,source.size.height<=8192 else{throw CocoaError(.fileReadCorruptFile)}
        let data=try Data(contentsOf:url),digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        if let existing=assets.first(where:{$0.digest==digest}){return existing}
        let id="custom-"+digest,path=storage.appendingPathComponent(id+"."+url.pathExtension.lowercased())
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try data.write(to:path,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        let asset=WallpaperAsset(id:id,title:url.deletingPathExtension().lastPathComponent,origin:"custom",styles:["未分类"],states:[],topics:[],path:path.path,digest:digest)
        var next=saved;next.custom.append(asset);try persist(next);saved=next;assets.append(asset);return asset
    }
    func image(for asset: WallpaperAsset)->NSImage? {
        if let image=images[asset.id]{return image}
        var image: NSImage?
        if let base=NSImage(contentsOfFile:asset.path) {
            if let quadrant=asset.quadrant,let cg=base.cgImage(forProposedRect:nil,context:nil,hints:nil),let crop=cg.cropping(to:CGRect(x:(quadrant%2)*cg.width/2,y:(quadrant/2)*cg.height/2,width:cg.width/2,height:cg.height/2)){image=NSImage(cgImage:crop,size:NSSize(width:240,height:240))}
            else{image=base}
        }
        if let image=image{images[asset.id]=image};return image
    }
}
