import AppKit
import UniformTypeIdentifiers

private final class WallpaperLibraryCanvas: MicSurface {
    override var isFlipped: Bool {true}
}
final class WallpaperLibraryWindow: NSObject, NSSearchFieldDelegate {
    let window: NSWindow
    let store: WallpaperLibrary
    weak var probe: Probe?
    private let search=NSSearchField(),origin=NSPopUpButton(),style=NSPopUpButton(),state=NSPopUpButton(),topic=NSPopUpButton()
    private let favorites=NSButton(checkboxWithTitle:"只看收藏",target:nil,action:nil)
    private let count=NSTextField(labelWithString:""),status=NSTextField(wrappingLabelWithString:"")
    private let grid=WallpaperLibraryCanvas(),detail=WallpaperLibraryCanvas(),preview=NSImageView()
    private let name=NSTextField(),styles=NSTextField(),states=NSTextField(),topics=NSTextField()
    private let provenance=NSTextField(wrappingLabelWithString:"")
    private var save: NSButton!,favorite: NSButton!,use: NSButton!
    private var selectedID: String?
    init(probe: Probe){
        self.probe=probe;store=WallpaperLibrary(root:URL(fileURLWithPath:projectRoot));window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:680),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        super.init();window.title="Mic Pro · 图案素材库";window.isReleasedWhenClosed=false;window.appearance=nil;window.backgroundColor=MicStyle.paper
        let root=WallpaperLibraryCanvas(frame:NSRect(x:0,y:0,width:1000,height:680));window.contentView=root
        MicStyle.label("图案素材库",in:root,frame:NSRect(x:22,y:19,width:180,height:30),size:21,weight:.semibold)
        search.frame=NSRect(x:214,y:20,width:380,height:30);search.placeholderString="搜索名称、风格、状态或主题";search.delegate=self;root.addSubview(search)
        count.frame=NSRect(x:605,y:25,width:135,height:20);count.font = .systemFont(ofSize:11);count.textColor=MicStyle.muted;root.addSubview(count)
        MicStyle.button("导入自定义…",in:root,frame:NSRect(x:765,y:18,width:210,height:34),target:self,action:#selector(importFiles),symbol:"plus")
        origin.addItems(withTitles:["全部来源","官方参考","原创设计","自定义"])
        for (title,popup,y) in [("来源",origin,87.0),("风格",style,166.0),("状态",state,245.0),("主题",topic,324.0)]{
            MicStyle.label(title,in:root,frame:NSRect(x:22,y:y,width:172,height:20),size:11,muted:true);popup.frame=NSRect(x:18,y:y+26,width:178,height:30);popup.font = .systemFont(ofSize:11);popup.target=self;popup.action=#selector(filterChanged);popup.setAccessibilityLabel("素材"+title);root.addSubview(popup)
        }
        favorites.frame=NSRect(x:22,y:416,width:174,height:25);favorites.target=self;favorites.action=#selector(filterChanged);root.addSubview(favorites)
        MicStyle.button("清除筛选",in:root,frame:NSRect(x:18,y:460,width:178,height:29),target:self,action:#selector(clearFilters))
        MicStyle.label("导入图片复制保存，\n收藏与标签重启后保留。\n\n选择只打开预览，\n不会上传设备。",in:root,frame:NSRect(x:22,y:517,width:174,height:111),size:11,muted:true)
        let scroll=NSScrollView(frame:NSRect(x:214,y:74,width:526,height:552));scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.documentView=grid;root.addSubview(scroll)
        detail.frame=NSRect(x:761,y:74,width:219,height:552);detail.layer?.cornerRadius=14;detail.layer?.borderWidth=1;root.addSubview(detail)
        preview.frame=NSRect(x:20,y:12,width:179,height:159);preview.imageScaling = .scaleProportionallyUpOrDown;detail.addSubview(preview)
        provenance.frame=NSRect(x:16,y:178,width:190,height:50);provenance.font = .systemFont(ofSize:10);provenance.textColor=MicStyle.muted;detail.addSubview(provenance)
        for (label,field,y) in [("名称",name,231.0),("风格标签",styles,292.0),("状态标签",states,353.0),("主题标签",topics,414.0)] {
            MicStyle.label(label,in:detail,frame:NSRect(x:17,y:y,width:187,height:18),size:10,muted:true);field.frame=NSRect(x:16,y:y+21,width:187,height:26);field.font = .systemFont(ofSize:11);field.setAccessibilityLabel("图案"+label);detail.addSubview(field)
        }
        save=MicStyle.button("保存标签",in:detail,frame:NSRect(x:13,y:477,width:103,height:29),target:self,action:#selector(saveTags));favorite=MicStyle.button("收藏",in:detail,frame:NSRect(x:118,y:477,width:88,height:29),target:self,action:#selector(toggleFavorite),symbol:"star")
        use=MicStyle.button("选择并预览",in:detail,frame:NSRect(x:12,y:513,width:195,height:30),target:self,action:#selector(useSelected),primary:true)
        status.frame=NSRect(x:214,y:635,width:765,height:35);status.font = .systemFont(ofSize:11);status.textColor=MicStyle.muted;root.addSubview(status)
        window.center();updateMenus();refresh();status.stringValue=store.storageError ?? "官方图是截图参考；原创设计与自定义图分别保存。标签用中文逗号或英文逗号分隔。"
    }
    func show(){refresh();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    private func setMenu(_ popup:NSPopUpButton,values:[String],title:String){let selection=popup.titleOfSelectedItem;popup.removeAllItems();popup.addItems(withTitles:[title]+values);if let selection=selection,popup.itemTitles.contains(selection){popup.selectItem(withTitle:selection)}}
    private func updateMenus(){setMenu(style,values:store.values(\.styles),title:"全部风格");setMenu(state,values:store.values(\.states),title:"全部状态");setMenu(topic,values:store.values(\.topics),title:"全部主题")}
    private func filter()->WallpaperFilter {WallpaperFilter(query:search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),origin:origin.indexOfSelectedItem>0 ? ["","official","design","custom"][origin.indexOfSelectedItem] : "",style:style.indexOfSelectedItem>0 ? style.titleOfSelectedItem ?? "" : "",state:state.indexOfSelectedItem>0 ? state.titleOfSelectedItem ?? "" : "",topic:topic.indexOfSelectedItem>0 ? topic.titleOfSelectedItem ?? "" : "",favorites:favorites.state == .on)}
    @objc private func filterChanged(){refresh()}
    func controlTextDidChange(_ obj: Notification){refresh()}
    @objc private func clearFilters(){search.stringValue="";for p in [origin,style,state,topic]{p.selectItem(at:0)};favorites.state = .off;refresh()}
    private func refresh(){
        let visible=store.filtered(filter());count.stringValue="\(visible.count) / \(store.assets.count) 张";grid.subviews.forEach{$0.removeFromSuperview()};grid.frame=NSRect(x:0,y:0,width:510,height:max(552,CGFloat((visible.count+3)/4)*169))
        for (i,asset) in visible.enumerated(){
            let cell=WallpaperLibraryCanvas(frame:NSRect(x:CGFloat(i%4)*127,y:CGFloat(i/4)*169,width:118,height:157));cell.layer?.cornerRadius=10;cell.layer?.borderWidth=asset.id==selectedID ? 2 : 1;if asset.id==selectedID {cell.layer?.borderColor=MicStyle.green.cgColor};grid.addSubview(cell);if asset.id==selectedID{cell.layer?.borderColor=MicStyle.green.cgColor}
            let image=NSImageView(frame:NSRect(x:9,y:9,width:100,height:100));image.image=store.image(for:asset);image.imageScaling = .scaleProportionallyUpOrDown;cell.addSubview(image)
            let title=MicStyle.label((asset.favorite ? "★ " : "")+asset.title,in:cell,frame:NSRect(x:9,y:116,width:100,height:19),size:10);title.lineBreakMode = .byTruncatingTail
            MicStyle.label(asset.origin=="official" ? "截图参考" : asset.originLabel,in:cell,frame:NSRect(x:9,y:136,width:100,height:15),size:9,muted:true)
            let button=NSButton(title:asset.title,target:self,action:#selector(selectAsset(_:)));button.frame=cell.bounds;button.isTransparent=true;button.identifier=NSUserInterfaceItemIdentifier(asset.id);button.setAccessibilityLabel("选择图案："+asset.title);cell.addSubview(button)
        }
        if visible.isEmpty{MicStyle.label("没有匹配图案，试试清除筛选或导入图片。",in:grid,frame:NSRect(x:15,y:40,width:475,height:35),size:12,muted:true)}
        if let id=selectedID,!visible.contains(where:{$0.id==id}){selectedID=nil};updateDetail()
    }
    private var selected: WallpaperAsset? {store.assets.first(where:{$0.id==selectedID})}
    private func updateDetail(){
        guard let asset=selected else{preview.image=nil;provenance.stringValue="选择一张图案\n查看来源、标签并打开预览。";for field in [name,styles,states,topics]{field.stringValue="";field.isEnabled=false};save.isEnabled=false;favorite.isEnabled=false;use.isEnabled=false;return}
        preview.image=store.image(for:asset);provenance.stringValue=asset.originLabel+"\n"+(asset.origin=="official" ? "仅截图裁片，非官方壁纸原文件" : asset.origin=="custom" ? "已复制保存到本地素材库" : "四状态设计 · 尚未上机")
        name.stringValue=asset.title;styles.stringValue=asset.styles.joined(separator:"，");states.stringValue=asset.states.joined(separator:"，");topics.stringValue=asset.topics.joined(separator:"，");for field in [name,styles,states,topics]{field.isEnabled=store.storageError==nil};save.isEnabled=store.storageError==nil;favorite.isEnabled=save.isEnabled;favorite.title=asset.favorite ? "已收藏" : "收藏";use.isEnabled=preview.image != nil
    }
    @objc private func selectAsset(_ sender:NSButton){selectedID=sender.identifier?.rawValue;refresh()}
    private func tags(_ field:NSTextField)->[String]{var result=[String]();for part in field.stringValue.replacingOccurrences(of:"，",with:",").components(separatedBy:","){let tag=part.trimmingCharacters(in:.whitespacesAndNewlines);if !tag.isEmpty,!result.contains(tag){result.append(tag)}};return result}
    @objc private func saveTags(){guard let asset=selected else{return};do{try store.edit(id:asset.id,title:name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),styles:tags(styles),states:tags(states),topics:tags(topics),favorite:asset.favorite);updateMenus();refresh();status.stringValue="名称和标签已保存，重启后保留。"}catch{status.stringValue="无法保存：检查名称或素材库目录；原索引保留。"}}
    @objc private func toggleFavorite(){guard let asset=selected else{return};do{try store.edit(id:asset.id,title:asset.title,styles:asset.styles,states:asset.states,topics:asset.topics,favorite:!asset.favorite);refresh();status.stringValue="收藏状态已保存。"}catch{status.stringValue="收藏保存失败；原索引保留。"}}
    @objc private func importFiles(){
        let picker=NSOpenPanel();picker.allowedContentTypes=[.png,.jpeg];picker.allowsMultipleSelection=true;picker.message="复制图片到素材库；不会上传 Mic Pro。"
        guard picker.runModal() == .OK else{return};var failures=0,loaded=0
        for url in picker.urls {do{selectedID=try store.importImage(url).id;loaded+=1}catch{failures+=1}}
        clearFilters();updateMenus();refresh();status.stringValue="已读取 \(loaded) 张，\(failures) 张失败；相同文件自动去重。可编辑标签后手动预览。"
    }
    @objc private func useSelected(){guard let asset=selected,let image=store.image(for:asset),let probe=probe else{return};if probe.controlPanel?.wallpaperEditor==nil{probe.controlPanel?.wallpaperEditor=WallpaperEditor(probe:probe)};probe.controlPanel?.wallpaperEditor?.useImage(image,name:asset.title);probe.controlPanel?.wallpaperEditor?.show()}
}
