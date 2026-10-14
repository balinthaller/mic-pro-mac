import AppKit
import UniformTypeIdentifiers

final class MicDeviceView: NSView {
    var connected = false
    var recording = false
    var preview: NSImage?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        let scale=min(bounds.width/248,bounds.height/254);let transform=NSAffineTransform();transform.scale(by:scale);transform.concat()
        let shell=NSBezierPath(ovalIn:NSRect(x:22,y:32,width:204,height:204))
        let shadow=NSShadow();shadow.shadowBlurRadius=10;shadow.shadowOffset=NSSize(width:0,height:-3);shadow.shadowColor=NSColor.black.withAlphaComponent(0.16)
        NSGraphicsContext.saveGraphicsState();shadow.set();NSColor(calibratedWhite:0.32,alpha:1).setFill();shell.fill();NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting:NSColor(calibratedWhite:0.48,alpha:1),ending:NSColor(calibratedWhite:0.24,alpha:1))?.draw(in:shell,angle:280)
        NSColor(calibratedWhite:0.10,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:34,y:44,width:180,height:180)).fill()
        let screen=NSBezierPath(ovalIn:NSRect(x:39,y:49,width:170,height:170))
        NSGraphicsContext.saveGraphicsState();screen.addClip()
        NSColor(calibratedWhite:0.65,alpha:1).setFill();screen.fill()
        preview?.draw(in:NSRect(x:39,y:71.67,width:170,height:147.33),from:NSRect(x:0,y:32,width:240,height:208),operation:.sourceOver,fraction:1)
        // Bottom physical-label area is separate from the e-ink image.
        let band=NSBezierPath();band.move(to:NSPoint(x:45,y:91));band.curve(to:NSPoint(x:87,y:85),controlPoint1:NSPoint(x:61,y:72),controlPoint2:NSPoint(x:72,y:98));band.curve(to:NSPoint(x:163,y:85),controlPoint1:NSPoint(x:112,y:72),controlPoint2:NSPoint(x:143,y:72));band.curve(to:NSPoint(x:205,y:91),controlPoint1:NSPoint(x:178,y:98),controlPoint2:NSPoint(x:190,y:72));band.line(to:NSPoint(x:220,y:40));band.line(to:NSPoint(x:28,y:40));band.close();NSColor(calibratedWhite:0.07,alpha:1).setFill();band.fill()
        NSColor(calibratedWhite:0.62,alpha:1).setStroke()
        let power=NSBezierPath();power.appendArc(withCenter:NSPoint(x:90,y:68),radius:7,startAngle:125,endAngle:415,clockwise:false);power.lineWidth=2;power.stroke()
        let stem=NSBezierPath();stem.move(to:NSPoint(x:90,y:68));stem.line(to:NSPoint(x:90,y:79));stem.lineWidth=2;stem.stroke()
        for radius in [CGFloat(7),CGFloat(4.5)] {let rec=NSBezierPath(ovalIn:NSRect(x:158-radius,y:68-radius,width:radius*2,height:radius*2));rec.lineWidth=1.5;rec.stroke()}
        NSGraphicsContext.restoreGraphicsState()

    }
}

final class SidebarCanvas: MicSurface { override var isFlipped: Bool {true} }
final class MicSidePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool {true}
    override var canBecomeMain: Bool {false}
    override func cancelOperation(_ sender: Any?) {onEscape?()}
}
final class ControlPanel: NSObject, NSWindowDelegate {
    let window: MicSidePanel
    weak var probe: Probe?
    let root=SidebarCanvas(), body=SidebarCanvas(), controls=SidebarCanvas(), files=SidebarCanvas(), screenPage=SidebarCanvas(), overview=SidebarCanvas(), quotaPage=SidebarCanvas()
    let scroll=NSScrollView()
    let device=MicDeviceView()
    let screenDevice=MicDeviceView()
    var hardwareTitle: NSTextField!
    let overviewDevice=MicDeviceView()
    let overviewStatus=NSTextField(wrappingLabelWithString:"")
    let overviewQuota=CodexIconButton()
    let quotaDetail=NSTextField(wrappingLabelWithString:"")
    let connection=NSTextField(wrappingLabelWithString:"")
    let battery=NSTextField(labelWithString:"")
    let charging=NSTextField(labelWithString:"")
    let batteryNote=NSTextField(labelWithString:"")
    let activity=NSTextField(wrappingLabelWithString:"")
    let recording=NSTextField(labelWithString:"")
    let feedback=NSTextField(wrappingLabelWithString:"")
    let libraryStatus=NSTextField(wrappingLabelWithString:"")
    let progress=NSProgressIndicator()
    let input=NSPopUpButton(), output=NSPopUpButton()
    let tabs=NSSegmentedControl(labels:["概览","设备","录音","Codex"],trackingMode:.selectOne,target:nil,action:nil)
    let pin=NSButton(checkboxWithTitle:"固定",target:nil,action:nil)
    var actions=[NSButton](), connectionButton: NSButton!, handoffButton: NSButton!
    var wallpaperEditor: WallpaperEditor?
    var wallpaperLibrary: WallpaperLibraryWindow?
    var previewPath: String?
    var shortcutStatus=NSTextField(wrappingLabelWithString:"")
    var noise=NSTextField(labelWithString:"")
    var vibration=NSButton(checkboxWithTitle:"震动反馈",target:nil,action:nil)
    var leds=NSButton(checkboxWithTitle:"LED 指示灯",target:nil,action:nil)
    var settingsNote=NSTextField(wrappingLabelWithString:"")
    var selectedTab=0, screenID: NSNumber?, repositioning=false
    var observers=[NSObjectProtocol](), outsideMonitor: Any?
    var pinned: Bool {UserDefaults.standard.bool(forKey:"sidebarPinned")}
    init(probe: Probe?) {
        self.probe=probe
        window=MicSidePanel(contentRect:NSRect(x:0,y:0,width:400,height:820),styleMask:[.titled,.fullSizeContentView,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        window.title="Mic Pro · 控制面板";window.isReleasedWhenClosed=false;window.delegate=self
        window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true
        for button in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {window.standardWindowButton(button)?.isHidden=true}
        window.isMovable=false;window.level = .floating
        window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        window.becomesKeyOnlyIfNeeded=false;window.isFloatingPanel=true;window.hidesOnDeactivate = !pinned
        window.appearance=nil;window.backgroundColor=MicStyle.paper
        root.wantsLayer=true;root.layer?.backgroundColor=MicStyle.paper.cgColor;root.layer?.cornerRadius=14
        root.autoresizingMask=[.width,.height];window.contentView=root
        MicStyle.label("Mic Pro",in:root,frame:NSRect(x:22,y:18,width:190,height:24),size:14,weight:.semibold)
        pin.frame=NSRect(x:270,y:17,width:70,height:26);pin.target=self;pin.action=#selector(togglePin);root.addSubview(pin)
        let close=MicStyle.button("",in:root,frame:NSRect(x:349,y:16,width:30,height:28),target:self,action:#selector(hide),symbol:"xmark");close.setAccessibilityLabel("关闭面板")
        device.frame=NSRect(x:22,y:62,width:135,height:139);device.setAccessibilityLabel("最近验证的屏幕图案（本地缓存）");root.addSubview(device)
        hardwareTitle=MicStyle.label("你的 Mic Pro",in:root,frame:NSRect(x:174,y:75,width:200,height:28),size:23,weight:.semibold)
        connection.frame=NSRect(x:175,y:109,width:201,height:34);connection.font = .systemFont(ofSize:11);root.addSubview(connection)
        battery.frame=NSRect(x:173,y:146,width:135,height:40);battery.font = .monospacedDigitSystemFont(ofSize:31,weight:.medium);battery.textColor=MicStyle.ink;root.addSubview(battery)
        charging.font = .systemFont(ofSize:11,weight:.medium);root.addSubview(charging)
        batteryNote.frame=NSRect(x:175,y:190,width:205,height:16);batteryNote.font = .systemFont(ofSize:10);batteryNote.textColor=MicStyle.muted;root.addSubview(batteryNote)
        recording.frame=NSRect(x:24,y:212,width:353,height:22);recording.font = .systemFont(ofSize:11);recording.textColor=MicStyle.muted;root.addSubview(recording)
        tabs.frame=NSRect(x:22,y:244,width:356,height:30);tabs.target=self;tabs.action=#selector(tabChanged);tabs.selectedSegment=0;root.addSubview(tabs)
        scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.documentView=body;root.addSubview(scroll)
        for page in [overview,controls,files,screenPage,quotaPage] {body.addSubview(page)}
        buildControls();buildFiles();buildScreen();buildOverview();buildQuota()
        for view in controls.subviews {view.frame.origin.y += 175}
        for view in [device,hardwareTitle!,connection,battery,charging,batteryNote,recording] {view.removeFromSuperview();controls.addSubview(view)}
        device.frame=NSRect(x:0,y:0,width:125,height:129);hardwareTitle.frame=NSRect(x:141,y:10,width:209,height:28)
        connection.frame=NSRect(x:142,y:44,width:207,height:30);battery.frame=NSRect(x:140,y:79,width:108,height:38)
        charging.frame=NSRect(x:252,y:90,width:98,height:18)
        batteryNote.frame=NSRect(x:142,y:119,width:207,height:18);recording.frame=NSRect(x:2,y:147,width:347,height:22)
        tabs.frame=NSRect(x:22,y:60,width:356,height:30)
        progress.style = .spinning;progress.isDisplayedWhenStopped=false;root.addSubview(progress)
        feedback.font = .systemFont(ofSize:11);feedback.textColor=MicStyle.muted;root.addSubview(feedback)
        handoffButton=MicStyle.button("交给手机",in:root,frame:.zero,target:probe,action:#selector(Probe.toggleDeviceOwnership),symbol:"iphone")
        let more=MicStyle.button("更多设置",in:root,frame:.zero,target:self,action:#selector(showSettings),symbol:"ellipsis")
        more.identifier=NSUserInterfaceItemIdentifier("sidebarMore")
        window.onEscape={[weak self] in self?.hide()}
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.position(followMouse:false)})
        outsideMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]){[weak self] _ in guard let self=self,!self.pinned else{return};self.hide()}
        layout();selectTab(0);updatePin()
    }
    deinit {observers.forEach{NotificationCenter.default.removeObserver($0)};if let monitor=outsideMonitor {NSEvent.removeMonitor(monitor)}}
    func buildControls() {
        MicStyle.label("声音去哪里",in:controls,frame:NSRect(x:0,y:5,width:320,height:24),size:14,weight:.semibold)
        for (popup,y,tag,title,symbol) in [(input,42.0,0,"输入设备","mic"),(output,106.0,1,"输出设备","speaker.wave.2")] {
            MicStyle.label(title,in:controls,frame:NSRect(x:6,y:y,width:300,height:18),size:10,muted:true)
            popup.frame=NSRect(x:0,y:y+19,width:352,height:30);popup.font = .systemFont(ofSize:12);popup.target=probe;popup.action=#selector(Probe.selectPanelAudio(_:));popup.tag=tag;controls.addSubview(popup)
            popup.setAccessibilityLabel(title)
            popup.toolTip=symbol == "mic" ? "独立选择电脑输入，不改变输出" : "独立选择输出，不改变麦克风"
        }
        activity.frame=NSRect(x:4,y:173,width:344,height:43);activity.font = .systemFont(ofSize:11);activity.textColor=MicStyle.muted;controls.addSubview(activity)
        MicStyle.label("给一个轻提示",in:controls,frame:NSRect(x:0,y:224,width:320,height:25),size:14,weight:.semibold)
        actions.append(MicStyle.button("震动一下",in:controls,frame:NSRect(x:0,y:260,width:170,height:47),target:probe,action:#selector(Probe.vibrateAndReconnect),symbol:"waveform"))
        actions.append(MicStyle.button("灯光闪一下",in:controls,frame:NSRect(x:181,y:260,width:171,height:47),target:probe,action:#selector(Probe.blinkLights),symbol:"lightbulb"))
        MicStyle.label("提示结束后恢复原设置",in:controls,frame:NSRect(x:3,y:316,width:344,height:20),size:10,muted:true)
        noise.frame=NSRect(x:3,y:352,width:344,height:22);noise.font = .systemFont(ofSize:12);controls.addSubview(noise)
        for (button,y,action) in [(vibration,386.0,#selector(Probe.toggleVibration)),(leds,420.0,#selector(Probe.toggleLeds))] {
            button.frame=NSRect(x:2,y:y,width:347,height:25);button.target=probe;button.action=action;button.font = .systemFont(ofSize:12);controls.addSubview(button)
        }
        settingsNote.frame=NSRect(x:3,y:452,width:344,height:40);settingsNote.font = .systemFont(ofSize:10);settingsNote.textColor=MicStyle.muted;controls.addSubview(settingsNote)
        connectionButton=MicStyle.button("连接麦克风",in:controls,frame:NSRect(x:0,y:501,width:171,height:32),target:probe,action:#selector(Probe.toggleBluetooth),symbol:"link")
        MicStyle.button("电量与续航…",in:controls,frame:NSRect(x:181,y:501,width:171,height:32),target:probe,action:#selector(Probe.showPowerDashboard),symbol:"battery.100")
    }
    func buildFiles() {
        MicStyle.label("设备内录",in:files,frame:NSRect(x:0,y:5,width:352,height:24),size:14,weight:.semibold)
        libraryStatus.frame=NSRect(x:1,y:37,width:350,height:42);libraryStatus.font = .systemFont(ofSize:11);libraryStatus.textColor=MicStyle.muted;files.addSubview(libraryStatus)
        MicStyle.label("刷新后选择一条导出，原文件保留。",in:files,frame:NSRect(x:1,y:84,width:350,height:20),size:10,muted:true)
    }
    func buildScreen() {
        MicStyle.label("墨水屏图案",in:screenPage,frame:NSRect(x:0,y:5,width:352,height:24),size:14,weight:.semibold)
        screenDevice.frame=NSRect(x:82,y:37,width:190,height:194);screenPage.addSubview(screenDevice)
        MicStyle.label("最近验证图案 · 本地缓存",in:screenPage,frame:NSRect(x:1,y:241,width:352,height:24),size:11,muted:true)
        MicStyle.label("写入前自动完整备份，完成后可恢复。",in:screenPage,frame:NSRect(x:1,y:276,width:352,height:24),size:11,muted:true)
        for (title,y,selector,symbol) in [("图案素材库…",317.0,#selector(Probe.chooseWallpaperImage),"photo"),("备份当前图案",363.0,#selector(Probe.backupWallpaper),"square.and.arrow.down"),("恢复图案…",409.0,#selector(Probe.chooseWallpaperRestore),"arrow.uturn.backward")] {
            actions.append(MicStyle.button(title,in:screenPage,frame:NSRect(x:0,y:y,width:352,height:34),target:probe,action:selector,symbol:symbol))
        }
    }
    func buildOverview(){
        MicStyle.label("现在的状态",in:overview,frame:NSRect(x:0,y:4,width:352,height:32),size:23,weight:.semibold)
        overviewDevice.frame=NSRect(x:0,y:49,width:80,height:84);overview.addSubview(overviewDevice)
        overviewStatus.frame=NSRect(x:92,y:50,width:259,height:100);overviewStatus.font = .systemFont(ofSize:11);overviewStatus.textColor=MicStyle.muted;overview.addSubview(overviewStatus)
        MicStyle.button("设备详情",in:overview,frame:NSRect(x:0,y:151,width:352,height:32),target:self,action:#selector(openDevice),symbol:"mic")
        overviewQuota.frame=NSRect(x:0,y:205,width:352,height:44);overviewQuota.bezelStyle = .rounded;overviewQuota.target=self;overviewQuota.action=#selector(openQuota);overview.addSubview(overviewQuota)
        MicStyle.label("继续最近的操作",in:overview,frame:NSRect(x:2,y:278,width:350,height:22),size:11,muted:true)
        MicStyle.button("设备内录文件 · 蓝牙 / USB",in:overview,frame:NSRect(x:0,y:315,width:352,height:34),target:probe,action:#selector(Probe.showRecordingFiles),symbol:"folder")
        MicStyle.button("墨水屏图案",in:overview,frame:NSRect(x:0,y:365,width:352,height:34),target:self,action:#selector(openScreen),symbol:"photo")
    }
    func buildQuota(){
        MicStyle.label("Codex 额度",in:quotaPage,frame:NSRect(x:0,y:4,width:352,height:32),size:23,weight:.semibold)
        quotaDetail.frame=NSRect(x:2,y:58,width:348,height:262);quotaDetail.font = .systemFont(ofSize:14);quotaDetail.textColor=MicStyle.ink;quotaPage.addSubview(quotaDetail)
        MicStyle.button("刷新额度",in:quotaPage,frame:NSRect(x:0,y:332,width:352,height:34),target:self,action:#selector(refreshQuota),symbol:"arrow.clockwise")
        MicStyle.label("账户共享额度与本项目 token 消耗分开。",in:quotaPage,frame:NSRect(x:2,y:384,width:348,height:26),size:11,muted:true)
    }
    @objc func openDevice(){selectTab(1)}
    @objc func openQuota(){selectTab(3)}
    @objc func openScreen(){selectTab(4)}
    @objc func refreshQuota(){probe?.codexQuota.refresh(force:true)}
    func layout() {
        let height=root.bounds.height
        scroll.frame=NSRect(x:24,y:107,width:352,height:max(40,height-207))
        let contentHeight: CGFloat=selectedTab == 1 ? 725 : selectedTab == 2 ? 610 : selectedTab == 4 ? 472 : 470
        body.frame=NSRect(x:0,y:0,width:352,height:contentHeight)
        for page in [overview,controls,files,screenPage,quotaPage] {page.frame=body.bounds}
        progress.frame=NSRect(x:23,y:height-89,width:16,height:16)
        feedback.frame=NSRect(x:46,y:height-94,width:331,height:40)
        handoffButton.frame=NSRect(x:18,y:height-43,width:163,height:30)
        root.subviews.first(where:{$0.identifier?.rawValue == "sidebarMore"})?.frame=NSRect(x:248,y:height-43,width:134,height:30)
    }
    func position(followMouse: Bool) {
        let screens=NSScreen.screens
        let matching = followMouse ? screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) : screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID})
        guard let screen=matching ?? NSScreen.main ?? screens.first else{return}
        screenID=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        repositioning=true;window.setFrame(SidebarPresentation.frame(in:screen.visibleFrame),display:true);repositioning=false;layout()
    }
    func show() {position(followMouse:true);NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);UserDefaults.standard.set(true,forKey:"sidebarWasVisible");updatePin()}
    @objc func hide() {window.orderOut(nil);UserDefaults.standard.set(false,forKey:"sidebarWasVisible")}
    func toggle(){if window.isVisible {hide()} else {show();if let probe=probe {update(probe:probe)}}}
    func windowDidResignKey(_ notification: Notification) {if !pinned,window.attachedSheet == nil {hide()}}
    func windowDidResize(_ notification: Notification) {layout()}
    func windowShouldClose(_ sender: NSWindow) -> Bool {hide();return false}
    @objc func togglePin(){UserDefaults.standard.set(pin.state == .on,forKey:"sidebarPinned");updatePin()}
    func updatePin(){pin.state=pinned ? .on : .off;window.hidesOnDeactivate = !pinned;pin.toolTip=pinned ? "固定展开：切换应用仍显示；Esc或快捷键可隐藏" : "临时展开：点击外部收起"}
    @objc func tabChanged(){selectTab(tabs.selectedSegment)}
    func selectTab(_ value: Int) {
        selectedTab=value;tabs.selectedSegment=value<4 ? value : -1
        overview.isHidden=value != 0;controls.isHidden=value != 1;files.isHidden=value != 2;quotaPage.isHidden=value != 3;screenPage.isHidden=value != 4
        if value == 2,let probe=probe {
            if probe.recordingFilesWindow == nil {probe.recordingFilesWindow=RecordingFilesWindow(probe:probe)}
            if let recorder=probe.recordingFilesWindow,recorder.embeddedView == nil {
                let content=recorder.embeddedContent();content.frame=NSRect(x:0,y:113,width:352,height:487);files.addSubview(content)
            }
        }
        layout();scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc func showSettings(_ sender: NSButton) {
        let menu=NSMenu();menu.autoenablesItems=false
        let shortcut=NSMenuItem(title:"呼出快捷键",action:nil,keyEquivalent:"");let choices=NSMenu()
        for (index,label) in PanelShortcut.labels.enumerated() {
            let item=choices.addItem(withTitle:label,action:#selector(selectShortcut(_:)),keyEquivalent:"");item.tag=index;item.target=self;item.state=probe?.panelShortcut?.selection == index ? .on : .off
        }
        shortcut.submenu=choices;menu.addItem(shortcut)
        if let error=probe?.panelShortcut?.error {let item=NSMenuItem(title:error,action:nil,keyEquivalent:"");item.isEnabled=false;menu.addItem(item)}
        menu.addItem(.separator())
        if let dock=probe?.edgeDock {
            let enabled=menu.addItem(withTitle:"边缘停靠条",action:#selector(EdgeDock.toggleEnabled),keyEquivalent:"");enabled.target=dock;enabled.state=dock.enabled ? .on : .off
            let compact=menu.addItem(withTitle:"停靠条紧凑显示",action:#selector(EdgeDock.toggleCompact),keyEquivalent:"");compact.target=dock;compact.state=dock.compact ? .on : .off;compact.isEnabled=dock.enabled
            let always=menu.addItem(withTitle:"停靠条保持展开",action:#selector(EdgeDock.toggleAlways),keyEquivalent:"");always.target=dock;always.state=dock.always ? .on : .off;always.isEnabled=dock.enabled
        }
        let diagnostic=menu.addItem(withTitle:"蓝牙诊断…",action:#selector(Probe.showDiagnostic),keyEquivalent:"");diagnostic.target=probe
        let advanced=menu.addItem(withTitle:"全部设置…",action:#selector(showAdvanced(_:)),keyEquivalent:"");advanced.target=self
        let version=NSMenuItem(title:"Mic Pro "+AppVersion.version,action:nil,keyEquivalent:"");version.isEnabled=false;menu.addItem(version)
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)
    }
    @objc func showAdvanced(_ sender: NSMenuItem){probe?.showMoreMenu(handoffButton)}
    @objc func selectShortcut(_ sender: NSMenuItem){probe?.panelShortcut?.select(sender.tag);if let probe=probe {update(probe:probe)}}
    func update(probe: Probe) {
        guard window.isVisible else{return}
        let connected=SystemBattery.device()?.isConnected() == true,busy=probe.deviceTransactionBusy,usb=probe.connectedUSBVolumes().first
        let text=probe.powerStrings()
        connection.stringValue=probe.handoffSuppressed ? probe.handoffDescription : usb.map{"USB · "+$0.root.lastPathComponent+(connected ? " · 音频已连接" : " · 音频未连接")} ?? (connected ? "蓝牙已连接 · \(DeviceConfig.serialSuffix)" : "设备未连接 · \(DeviceConfig.serialSuffix)")
        connection.textColor=connected || usb != nil ? MicStyle.green : MicStyle.muted
        battery.stringValue=probe.batteryLevel.map{"\($0)%"} ?? "—"
        charging.stringValue=probe.chargingLabel;charging.textColor=probe.currentBatteryPower?.info.powerType == 1 ? MicStyle.green : MicStyle.muted;charging.toolTip=probe.chargingTooltip
        batteryNote.stringValue=probe.batteryIsCached ? "上次读取 · 等待更新" : probe.batteryLevel == nil ? "电量暂不可读" : "macOS / 设备报告值"
        activity.stringValue=text.activity.replacingOccurrences(of:"电脑收音：未检测到软件正在采集",with:"当前没有软件在收音")
        recording.stringValue=text.recording
        libraryStatus.stringValue=usb == nil ? "蓝牙录音目录 · 接USB可浏览WAV" : "USB录音盘已连接 · OGG / WAV"
        let path=UserDefaults.standard.string(forKey:"lastVerifiedWallpaperPNG")
        if previewPath != path {previewPath=path;let image=path.flatMap{NSImage(contentsOfFile:$0)};device.preview=image;screenDevice.preview=image}
        overviewDevice.preview=device.preview
        overviewStatus.stringValue=(probe.batteryLevel.map{"电量 \($0)%"} ?? "电量暂不可读")+" · "+probe.chargingLabel+" · "+connection.stringValue+"\n"+text.activity+"\n"+text.recording
        overviewQuota.title="Codex · "+(probe.codexQuota.snapshot?.windows.first?.label ?? "账户额度")+"剩余 "+probe.codexQuota.summary
        quotaDetail.stringValue=probe.codexQuota.detail
        for view in [device,screenDevice,overviewDevice] {view.connected=connected;view.recording=probe.currentRecording == true;view.needsDisplay=true}
        for button in actions {button.isEnabled = !busy && (button.action == #selector(Probe.chooseWallpaperImage) || (probe.primaryControlAvailable && probe.peripheral == nil))}
        connectionButton.title=connected ? "断开麦克风" : "连接麦克风";connectionButton.isEnabled = !busy && !probe.handoffSuppressed && SystemBattery.device() != nil
        handoffButton.title=probe.handoffSuppressed ? "连接回 Mac" : "交给手机";handoffButton.isEnabled = !busy && SystemBattery.device() != nil
        let fresh=probe.currentRecording != nil
        let more=probe.authorized ? probe.moreSettings : (fresh ? probe.latestMore : nil)
        for (button,offset) in [(vibration,9),(leds,10)] {button.state=more.flatMap{$0.count>offset ? ($0[offset]==1 ? NSControl.StateValue.on : .off) : nil} ?? .mixed;button.isEnabled = !busy && !probe.handoffSuppressed && probe.authorized && probe.peripheral?.state == .connected && probe.moreSettings != nil}
        settingsNote.stringValue=vibration.isEnabled ? "已授权设置控制通道可写" : "设置开关暂不可写；震动和灯光提示可单独使用。"
        if fresh,let common=probe.latestCommon,common.count>3 {noise.stringValue="降噪强度："+([0:"关闭",1:"轻度",2:"强"][Int(common[3])] ?? "设备值 \(common[3])")+" · 最近读取"} else {noise.stringValue="降噪强度：等待有效设备状态"}
        if busy {progress.startAnimation(nil)} else {progress.stopAnimation(nil)}
        feedback.stringValue=probe.panelShortcut?.error ?? probe.recordingTransferSnapshot()?["phase"] as? String ?? (busy ? "正在处理设备事务，请稍候…" : probe.lastActionSummary ?? "\(probe.panelShortcut?.label ?? "⌃⌥M") 呼出 · Esc 收起")
        MicStyle.configureRoutes([input,output]);input.isEnabled = !busy;output.isEnabled = !busy
    }
}
extension Probe {
    @objc func toggleControlPanel() {
        if controlPanel == nil {controlPanel=ControlPanel(probe:self)}
        menuPopover?.close();controlPanel?.toggle()
    }
    @objc func showControlPanel() {
        if controlPanel == nil { controlPanel = ControlPanel(probe:self) }
        menuPopover?.close();controlPanel?.show();controlPanel?.update(probe:self)
    }
    @objc func selectPanelAudio(_ popup: NSPopUpButton) {
        guard let uid = popup.selectedItem?.representedObject as? String else { return }
        do { try AudioRouting.select(uid:uid,direction:popup.tag == 0 ? .input : .output);lastActionSummary = "已切换" + (popup.tag == 0 ? "输入" : "输出") + "：" + (popup.titleOfSelectedItem ?? "") }
        catch { lastActionSummary = "音频选择失败：" + error.localizedDescription }
        controlPanel?.update(probe:self);menuPopover?.update(probe:self);edgeDock?.refresh()
    }
    @objc func chooseWallpaperImage() {
        if controlPanel == nil { controlPanel=ControlPanel(probe:self) }
        if controlPanel?.wallpaperLibrary == nil { controlPanel?.wallpaperLibrary=WallpaperLibraryWindow(probe:self) }
        controlPanel?.wallpaperLibrary?.show()
    }
    @objc func chooseWallpaperRestore() {
        let picker = NSOpenPanel();picker.canChooseDirectories = true;picker.canChooseFiles = false;picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath:projectRoot+"/backups");picker.message = "选择要恢复的壁纸备份目录。"
        guard picker.runModal() == .OK,let url = picker.url else { return }
        startWallpaperUpload(id:UUID().uuidString,action:"wallpaper-restore",image:nil,backup:url.path)
    }
}

extension Probe {
    func handleUIResult(id: String,payload: [String:Any]) {
        let ok = payload["ok"] as? Bool == true
        if let action = payload["action"] as? String {
            let names = ["vibrate":"震动提示","blink":"灯光提示","wallpaper-backup":"壁纸备份","wallpaper-upload":"图片上传","wallpaper-restore":"壁纸恢复"]
            if let name = names[action] { lastActionSummary = ok ? name + "完成 · 已校验设备回复" : name + "失败：" + (payload["error"] as? String ?? "请查看诊断日志") }
        } else if let error = payload["error"] as? String { lastActionSummary = "操作未完成：" + error }
        guard let workflow = screenUI,workflow.id == id else { return }
        if let backup = workflow.acceptBackup(payload) {
            DispatchQueue.main.async { [weak self] in self?.startWallpaperUpload(id:workflow.id,action:"wallpaper-upload",image:workflow.image,backup:backup) }
        } else { screenUI = nil }
    }
}
