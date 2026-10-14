import AppKit
import UniformTypeIdentifiers

final class WallpaperPreview: NSView {
    var image: NSImage?
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite:0.63,alpha:1).setFill();bounds.fill()
        image?.draw(in:bounds,from:NSRect(x:0,y:32,width:240,height:208),operation:.sourceOver,fraction:1)
    }
}
final class WallpaperEditor: NSObject {
    let window: NSWindow
    weak var probe: Probe?
    let preview=WallpaperPreview(frame:NSRect(x:35,y:234,width:270,height:234))
    let fit=NSPopUpButton();let background=NSPopUpButton();let preset=NSPopUpButton()
    let dither=NSButton(checkboxWithTitle:"抖色：保留渐变细节",target:nil,action:nil)
    let saturation=NSSlider(value:1,minValue:0,maxValue:2,target:nil,action:nil)
    let x=NSSlider(value:0,minValue:-1,maxValue:1,target:nil,action:nil)
    let y=NSSlider(value:0,minValue:-1,maxValue:1,target:nil,action:nil)
    let status=NSTextField(wrappingLabelWithString:"")
    var source: NSImage?
    var rendered: Data?
    var sourceName=""
    init(probe: Probe) {
        self.probe=probe;window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:520),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        super.init();window.title="Mic Pro · 图片预览";window.isReleasedWhenClosed=false;window.appearance=nil;window.backgroundColor=MicStyle.paper
        let root=window.contentView!;root.addSubview(preview)
        MicStyle.label("屏幕图案",in:root,frame:NSRect(x:30,y:472,width:240,height:28),size:20,weight:.semibold)
        MicStyle.label("实际渲染240×208 · 上传与此预览一致",in:root,frame:NSRect(x:30,y:187,width:310,height:22),size:11,muted:true)
        MicStyle.button("选择 PNG / JPEG…",in:root,frame:NSRect(x:340,y:450,width:300,height:34),target:self,action:#selector(choose))
        preset.frame=NSRect(x:343,y:409,width:293,height:28);preset.addItems(withTitles:["选择预设…","专注","休息","完成"]);preset.target=self;preset.action=#selector(choosePreset);root.addSubview(preset)
        fit.frame=NSRect(x:415,y:365,width:220,height:27);fit.addItems(withTitles:["完整显示（保留边缘）","填满（裁切边缘）"])
        background.frame=NSRect(x:415,y:324,width:220,height:27);background.addItems(withTitles:["黑","灰","黄","红","蓝","绿"]);background.selectItem(at:1)
        for (title,v,frame) in [("适配",fit,NSRect(x:342,y:369,width:65,height:20)),("背景",background,NSRect(x:342,y:328,width:65,height:20))] {MicStyle.label(title,in:root,frame:frame,size:12,muted:true);v.target=self;v.action=#selector(updatePreview);root.addSubview(v)}
        dither.frame=NSRect(x:343,y:279,width:300,height:27);dither.target=self;dither.action=#selector(updatePreview);root.addSubview(dither)
        for (title,slider,yy) in [("鲜艳度",saturation,240.0),("水平裁切",x,202.0),("垂直裁切",y,164.0)] {MicStyle.label(title,in:root,frame:NSRect(x:343,y:yy,width:80,height:23),size:12,muted:true);slider.frame=NSRect(x:423,y:yy,width:210,height:25);slider.target=self;slider.action=#selector(updatePreview);root.addSubview(slider)}
        status.frame=NSRect(x:30,y:83,width:610,height:64);status.font = .systemFont(ofSize:12);status.textColor=MicStyle.muted;root.addSubview(status)
        MicStyle.button("备份后上传",in:root,frame:NSRect(x:495,y:24,width:146,height:34),target:self,action:#selector(upload),primary:true)
        MicStyle.button("关闭",in:root,frame:NSRect(x:338,y:24,width:146,height:34),target:self,action:#selector(close))
        x.isEnabled=false;y.isEnabled=false
        window.center();status.stringValue="选择图片或预设。预览只在本地处理，点击上传才会连接设备并完整备份。"
    }
    func useImage(_ image:NSImage,name:String){source=image;sourceName=name;fit.selectItem(at:0);dither.state = .off;saturation.doubleValue=1;x.doubleValue=0;y.doubleValue=0;updatePreview()}
    func show(){window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func close(){window.close()}
    @objc func choose(){
        let picker=NSOpenPanel();picker.allowedContentTypes=[.png,.jpeg];picker.allowsMultipleSelection=false
        guard picker.runModal() == .OK,let url=picker.url else{return}
        do {source=try loadWallpaperSource(url);sourceName=url.lastPathComponent;x.doubleValue=0;y.doubleValue=0;updatePreview()}
        catch {status.stringValue="图片无法读取，请选20MB以内的PNG/JPEG。仍保留之前的预览。"}
    }
    @objc func choosePreset(){
        guard preset.indexOfSelectedItem>0 else{return}
        let text=preset.titleOfSelectedItem ?? "专注";sourceName="预设："+text
        let image=NSImage(size:NSSize(width:240,height:208));image.lockFocus()
        NSColor(calibratedWhite:0.63,alpha:1).setFill();NSRect(x:0,y:0,width:240,height:208).fill()
        NSColor(calibratedRed:50.0/255,green:100.0/255,blue:70.0/255,alpha:1).setFill();NSRect(x:40,y:36,width:160,height:4).fill();NSRect(x:40,y:168,width:160,height:4).fill()
        (text as NSString).draw(in:NSRect(x:53,y:76,width:170,height:54),withAttributes:[.font:NSFont.systemFont(ofSize:40,weight:.medium),.foregroundColor:NSColor(calibratedWhite:30.0/255,alpha:1)])
        image.unlockFocus();source=image;x.doubleValue=0;y.doubleValue=0;updatePreview()
    }
    @objc func updatePreview(){
        guard let source=source else{return}
        do {
            let options=WallpaperRenderOptions(fit:fit.indexOfSelectedItem==1 ? .cover : .contain,background:background.indexOfSelectedItem,dither:dither.state == .on,saturation:saturation.doubleValue,x:x.doubleValue,y:y.doubleValue)
            rendered=try renderedWallpaper(image:source,options:options);preview.image=rendered.flatMap{NSImage(data:$0)};preview.needsDisplay=true
            x.isEnabled=options.fit == .cover;y.isEnabled=options.fit == .cover
            status.stringValue=sourceName+" · 六色屏幕预览\n完整显示保留图像比例；填满可移动裁切。预览不上传，上传后可用备份恢复原图。"
        } catch {rendered=nil;preview.image=nil;preview.needsDisplay=true;status.stringValue="预览生成失败；未连接或修改设备。"}
    }
    @objc func upload(){
        guard let probe=probe else{return}
        guard !probe.deviceTransactionBusy,!probe.handoffSuppressed,probe.primaryControlAvailable else {status.stringValue="请先连接回 Mac 并等待当前操作完成；预览仍可编辑。";return}
        guard let data=rendered else {status.stringValue="请先选择图片或预设。";return}
        do {
            let folder=URL(fileURLWithPath:projectRoot+"/logs/wallpaper-previews");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let path=folder.appendingPathComponent(UUID().uuidString+".png");try data.write(to:path,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
            let id=UUID().uuidString;probe.screenUI=ScreenUIWorkflow(id:id,image:path.path);probe.startWallpaperBackup(id:id)
            status.stringValue="正在完整备份当前图案；备份成功后才上传此预览。";window.close();probe.showControlPanel()
        } catch {status.stringValue="无法保存预览，未连接或修改设备。"}
    }
}
