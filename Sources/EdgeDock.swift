import AppKit

private final class EdgePanel: NSPanel {
    var acceptsKey=false
    override var canBecomeKey: Bool {acceptsKey}
    override var canBecomeMain: Bool {false}
}
private class EdgeSurface: MicSurface {
    var onDrag: ((CGFloat,NSPoint) -> Void)?
    var onSettings: ((NSEvent) -> Void)?
    var onHover: (() -> Void)?
    private var hoverTracking:NSTrackingArea?
    override func updateTrackingAreas(){
        if let old=hoverTracking{removeTrackingArea(old)}
        let area=NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
        hoverTracking=area;addTrackingArea(area);super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent){onHover?()}
    private var startY: CGFloat?
    override func mouseDown(with event: NSEvent){startY=window?.convertPoint(toScreen:event.locationInWindow).y}
    override func mouseDragged(with event: NSEvent){if let y=startY,let point=window?.convertPoint(toScreen:event.locationInWindow){onDrag?(point.y-y,point);startY=point.y}}
    override func rightMouseDown(with event: NSEvent){onSettings?(event)}

    var edgeRadius: CGFloat=12
    override func refreshColors(){super.refreshColors();layer?.backgroundColor=NSColor.clear.cgColor;layer?.borderWidth=0;layer?.cornerRadius=0}
    override func draw(_ dirtyRect: NSRect){
        let b=bounds.insetBy(dx:0.5,dy:0.5),r=min(edgeRadius,b.height/2),k=r*0.5522847498,p=NSBezierPath()
        p.move(to:NSPoint(x:b.minX+r,y:b.minY));p.line(to:NSPoint(x:b.maxX,y:b.minY));p.line(to:NSPoint(x:b.maxX,y:b.maxY));p.line(to:NSPoint(x:b.minX+r,y:b.maxY))
        p.curve(to:NSPoint(x:b.minX,y:b.maxY-r),controlPoint1:NSPoint(x:b.minX+r-k,y:b.maxY),controlPoint2:NSPoint(x:b.minX,y:b.maxY-r+k))
        p.line(to:NSPoint(x:b.minX,y:b.minY+r));p.curve(to:NSPoint(x:b.minX+r,y:b.minY),controlPoint1:NSPoint(x:b.minX,y:b.minY+r-k),controlPoint2:NSPoint(x:b.minX+r-k,y:b.minY));p.close()
        MicStyle.paper.withAlphaComponent(0.97).setFill();p.fill();MicStyle.line.setStroke();p.lineWidth=1;p.stroke()
    }
}
private final class EdgeHandle: EdgeSurface {
    var onClick: (() -> Void)?
    var batteryText="—",quotaText="—"
    var batteryRemaining: Double?,quotaRemaining: Double?
    override func draw(_ dirtyRect: NSRect){
        // Only the two status tracks occupy the edge; no panel background, icon or text.
        let margin:CGFloat=8,gap:CGFloat=8
        let height=max(1,(bounds.height-margin*2-gap)/2)
        let width:CGFloat=4,x=max(0,bounds.width-width-1)
        func track(_ remaining:Double?,y:CGFloat){
            let rect=NSRect(x:x,y:y,width:width,height:height)
            MicStyle.muted.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect:rect,xRadius:2,yRadius:2).fill()
            guard let remaining=remaining,remaining.isFinite,remaining>0 else{return}
            let filled=NSRect(x:x,y:y,width:width,height:height*min(100,remaining)/100)
            (remaining<15 ? NSColor.systemOrange : MicStyle.green).setFill()
            NSBezierPath(roundedRect:filled,xRadius:2,yRadius:2).fill()
        }
        track(batteryRemaining,y:margin+height+gap)
        track(quotaRemaining,y:margin)
    }
    override func mouseDown(with event: NSEvent){
        var last=window?.convertPoint(toScreen:event.locationInWindow) ?? .zero;let origin=last;var dragged=false
        while let next=window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp {if !dragged{onClick?()};break}
            let point=window?.convertPoint(toScreen:next.locationInWindow) ?? last
            if dragged || hypot(point.x-origin.x,point.y-origin.y)>4 {dragged=true;onDrag?(point.y-last.y,point);last=point}
        }
    }
}
private final class DockActionButton: NSButton {
    var onDrag: ((CGFloat,NSPoint) -> Void)?
    var onSettings: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent){onSettings?(event)}
    override func mouseDown(with event: NSEvent){
        var last=window?.convertPoint(toScreen:event.locationInWindow) ?? .zero;let origin=last;var dragged=false
        while let next=window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp {if !dragged{performClick(nil)};break}
            let point=window?.convertPoint(toScreen:next.locationInWindow) ?? last
            if dragged || hypot(point.x-origin.x,point.y-origin.y)>4 {dragged=true;onDrag?(point.y-last.y,point);last=point}
        }
    }
}
private final class QuotaRing: NSView {
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    var remaining: Double?
    override func draw(_ dirtyRect: NSRect){
        let center=NSPoint(x:bounds.midX,y:bounds.midY),radius=min(bounds.width,bounds.height)/2-3
        let base=NSBezierPath(ovalIn:NSRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2));base.lineWidth=2;MicStyle.line.setStroke();base.stroke()
        if let remaining=remaining {let path=NSBezierPath();path.appendArc(withCenter:center,radius:radius,startAngle:90,endAngle:90-360*remaining/100,clockwise:true);path.lineWidth=2;(remaining<15 ? NSColor.systemOrange : MicStyle.green).setStroke();if remaining>0 {path.stroke()}}
        CodexIcon.image(for:effectiveAppearance)?.draw(in:bounds.insetBy(dx:5,dy:5))
    }
}
final class EdgeDock: NSObject, NSMenuDelegate {
    weak var probe: Probe?
    private let handle: EdgePanel,rail: EdgePanel,card: EdgePanel
    private let grip=EdgeHandle(frame:NSRect(x:0,y:0,width:8,height:124))
    private let device=MicDeviceView(), ring=QuotaRing()
    private let battery=NSTextField(labelWithString:""),quota=NSTextField(labelWithString:"")
    private let charging=NSTextField(labelWithString:"")
    private let title=NSTextField(labelWithString:"Mic Pro"),details=NSTextField(wrappingLabelWithString:""),value=NSTextField(labelWithString:"")
    private let connection=NSTextField(labelWithString:""),freshness=NSTextField(wrappingLabelWithString:"")
    private let input=NSPopUpButton(),output=NSPopUpButton(),inputLabel=NSTextField(labelWithString:"输入"),outputLabel=NSTextField(labelWithString:"输出")
    private var open: NSButton!,disconnect: NSButton!
    private var actionButtons=[DockActionButton]()
    private var lastArtwork=""
    private var lastDrag=Date.distantPast
    private var timer: Timer?,observers=[NSObjectProtocol](),intent=EdgeDockIntent()
    private var lastUI=Date.distantPast,hoverItem: Int?,screen: NSScreen?,previewPath: String?
    private var menuTracking=0
    var enabled: Bool {UserDefaults.standard.object(forKey:"edgeDockEnabled") as? Bool ?? true}
    var always: Bool {UserDefaults.standard.bool(forKey:"edgeDockAlwaysVisible")}
    var revealed: Bool {rail.isVisible}
    var compact: Bool {UserDefaults.standard.bool(forKey:"edgeDockCompact")}
    var position: Double {UserDefaults.standard.object(forKey:"edgeDockPosition") as? Double ?? 0.6}

    private static func panel(_ size: NSSize) -> EdgePanel {
        let window=EdgePanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=true;window.level = .floating
        window.hidesOnDeactivate=false;window.isFloatingPanel=true;window.becomesKeyOnlyIfNeeded=true;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle];window.appearance=nil;window.isMovable=false
        return window
    }
    init(probe: Probe){
        self.probe=probe;handle=Self.panel(NSSize(width:8,height:124));rail=Self.panel(NSSize(width:64,height:210));card=Self.panel(NSSize(width:284,height:332));super.init()
        handle.hasShadow=false;handle.title="Mic Pro · 边缘把手";rail.title="Mic Pro · 信息停靠条";card.title="Mic Pro · 状态与音频";card.acceptsKey=true
        grip.onClick={[weak self] in self?.intent.reveal();self?.wakeTracking();self?.apply()};handle.contentView=grip
        grip.onHover={[weak self] in self?.wakeTracking()}
        grip.onDrag={[weak self] in self?.drag(by:$0,point:$1)};grip.onSettings={[weak self] in self?.settings($0)}
        let root=EdgeSurface(frame:NSRect(x:0,y:0,width:64,height:210));root.edgeRadius=18;root.onHover={[weak self] in self?.wakeTracking()};root.onDrag={[weak self] in self?.drag(by:$0,point:$1)};root.onSettings={[weak self] in self?.settings($0)};rail.contentView=root
        device.frame=NSRect(x:4,y:142,width:56,height:58);root.addSubview(device)
        battery.frame=NSRect(x:3,y:127,width:58,height:17);battery.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium);battery.alignment = .center;root.addSubview(battery)
        ring.frame=NSRect(x:11,y:56,width:42,height:42);root.addSubview(ring)
        quota.frame=NSRect(x:3,y:33,width:58,height:20);quota.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium);quota.alignment = .center;root.addSubview(quota)
        for (y,height,name,selector) in [(123.0,83.0,"Mic Pro：连接或设备详情",#selector(Probe.handleDockMicClick)),(23.0,87.0,"Codex：额度详情",#selector(Probe.showCodexPanel))]{let button=DockActionButton(title:"",target:probe,action:selector);button.onDrag={[weak self] in self?.drag(by:$0,point:$1)};button.onSettings={[weak self] in self?.settings($0)};actionButtons.append(button);button.frame=NSRect(x:3,y:y,width:58,height:height);button.isBordered=false;button.setAccessibilityLabel(name);root.addSubview(button)}
        let info=MicSurface(frame:NSRect(x:0,y:0,width:284,height:332));info.layer?.cornerRadius=14;info.layer?.borderWidth=1;card.contentView=info
        title.frame=NSRect(x:18,y:290,width:155,height:25);title.font = .systemFont(ofSize:17,weight:.semibold);info.addSubview(title)
        connection.frame=NSRect(x:174,y:293,width:92,height:22);connection.font = .systemFont(ofSize:11);connection.alignment = .right;connection.textColor=MicStyle.green;info.addSubview(connection)
        value.frame=NSRect(x:17,y:238,width:248,height:40);value.font = .monospacedDigitSystemFont(ofSize:35,weight:.medium);info.addSubview(value)
        charging.font = .systemFont(ofSize:11,weight:.medium);info.addSubview(charging)
        details.frame=NSRect(x:18,y:167,width:248,height:62);details.font = .systemFont(ofSize:11);details.textColor=MicStyle.muted;info.addSubview(details)
        for (popup,label,y,tag) in [(input,inputLabel,124.0,0),(output,outputLabel,85.0,1)]{
            label.frame=NSRect(x:18,y:y+5,width:37,height:19);label.font = .systemFont(ofSize:11);label.textColor=MicStyle.muted;info.addSubview(label)
            popup.frame=NSRect(x:60,y:y,width:207,height:30);popup.font = .systemFont(ofSize:11);popup.tag=tag;popup.target=probe;popup.action=#selector(Probe.selectPanelAudio(_:));popup.setAccessibilityLabel(tag==0 ? "摘要输入设备" : "摘要输出设备");popup.menu?.delegate=self;info.addSubview(popup)
        }
        freshness.frame=NSRect(x:18,y:43,width:248,height:34);freshness.font = .systemFont(ofSize:10);freshness.textColor=MicStyle.muted;info.addSubview(freshness)
        open=MicStyle.button("设备详情",in:info,frame:NSRect(x:13,y:12,width:258,height:29),target:self,action:#selector(openDetails),symbol:"sidebar.right")
        disconnect=MicStyle.button("切到腾讯会议内录",in:info,frame:.zero,target:self,action:#selector(switchMeetingMode),symbol:"record.circle")
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.place()})
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in self?.place()})
        layout();place();refresh();start()
    }
    deinit{timer?.invalidate();for observer in observers {NotificationCenter.default.removeObserver(observer);NSWorkspace.shared.notificationCenter.removeObserver(observer)}}
    func menuWillOpen(_ menu: NSMenu){menuTracking+=1}
    func menuDidClose(_ menu: NSMenu){menuTracking=max(0,menuTracking-1);lastUI = .distantPast}
    private func start(){timer?.invalidate();timer=nil;guard enabled else{hideAll();return};scheduleTracking(active:false);tick()}
    private func scheduleTracking(active:Bool){
        let interval=active ? 0.12 : 1.0
        guard timer?.timeInterval != interval else{return}
        timer?.invalidate()
        let value=Timer(timeInterval:interval,repeats:true){[weak self] _ in self?.tick()};value.tolerance=active ? 0.025 : 0.15
        timer=value;RunLoop.main.add(value,forMode:.common)
    }
    private func wakeTracking(){guard enabled else{return};scheduleTracking(active:true);tick()}

    private func hideAll(){for window in [handle,rail,card] where window.isVisible{window.orderOut(nil)};intent.reset();hoverItem=nil}
    private func layout(){
        let w:CGFloat=compact ? 46 : 64,h:CGFloat=compact ? 158 : 210
        rail.contentView?.setFrameSize(NSSize(width:w,height:h))
        device.frame=NSRect(x:(w-(compact ? 40 : 56))/2,y:h-(compact ? 47 : 68),width:compact ? 40 : 56,height:compact ? 42 : 58)
        battery.frame=NSRect(x:2,y:h-(compact ? 62 : 83),width:w-4,height:17)
        ring.frame=NSRect(x:(w-(compact ? 32 : 42))/2,y:compact ? 41 : 56,width:compact ? 32 : 42,height:compact ? 32 : 42)
        quota.frame=NSRect(x:2,y:compact ? 21 : 33,width:w-4,height:18)
        for (i,button) in actionButtons.enumerated(){button.frame=i==0 ? NSRect(x:2,y:h/2,width:w-4,height:h/2) : NSRect(x:2,y:0,width:w-4,height:h/2)}
        let cw:CGFloat=compact ? 256 : 284,ch:CGFloat=compact ? 294 : 352
        card.contentView?.setFrameSize(NSSize(width:cw,height:ch))
        title.frame=NSRect(x:16,y:ch-40,width:cw-120,height:25);connection.frame=NSRect(x:cw-110,y:ch-37,width:94,height:22)
        charging.frame=NSRect(x:137,y:ch-76,width:cw-153,height:18)
        value.frame=NSRect(x:16,y:ch-88,width:cw-32,height:40);value.font = .monospacedDigitSystemFont(ofSize:compact ? 28 : 35,weight:.medium)
        details.frame=NSRect(x:16,y:ch-144,width:cw-32,height:52)
        for (popup,label,y) in [(input,inputLabel,compact ? 126.0 : 144.0),(output,outputLabel,compact ? 90.0 : 108.0)] {
            label.frame=NSRect(x:16,y:y+5,width:37,height:19);popup.frame=NSRect(x:58,y:y,width:cw-74,height:30)
        }
        freshness.frame=NSRect(x:16,y:67,width:cw-32,height:19)
        open.frame=NSRect(x:12,y:12,width:cw-24,height:27);disconnect.frame=NSRect(x:12,y:40,width:cw-24,height:25)
    }
    private func place(){
        let saved=UserDefaults.standard.object(forKey:"edgeDockDisplay") as? NSNumber
        screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)==saved}) ?? NSScreen.main ?? NSScreen.screens.first
        guard let area=screen?.visibleFrame else{return};place(in:area)
    }
    private func place(in area:NSRect){
        let size=NSSize(width:compact ? 46 : 64,height:compact ? 158 : 210)
        let frame=EdgeDockLayout.frame(in:area,size:size,fraction:position);rail.setFrame(frame,display:true)
        handle.setFrame(EdgeDockLayout.frame(in:area,size:NSSize(width:8,height:compact ? 98 : 124),fraction:position),display:true)
        let cw:CGFloat=compact ? 256 : 284,ch:CGFloat=compact ? 294 : 352
        card.setFrame(NSRect(x:max(area.minX,frame.minX-cw-8),y:max(area.minY,min(area.maxY-ch,frame.midY-ch/2)),width:cw,height:ch),display:true)
    }
    private func drag(by delta:CGFloat,point:NSPoint){
        lastDrag=Date()
        if let target=NSScreen.screens.first(where:{$0.visibleFrame.contains(point)}){screen=target}
        guard let screen=screen else{return}
        let center=rail.frame.midY+delta
        UserDefaults.standard.set(EdgeDockLayout.fraction(centerY:center,in:screen.visibleFrame),forKey:"edgeDockPosition")
        UserDefaults.standard.set(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")],forKey:"edgeDockDisplay")
        place(in:screen.visibleFrame);card.orderOut(nil);hoverItem=nil
    }
    private func settings(_ event:NSEvent){
        let menu=NSMenu();menu.autoenablesItems=false
        let size=menu.addItem(withTitle:"紧凑显示",action:#selector(toggleCompact),keyEquivalent:"");size.target=self;size.state=compact ? .on : .off
        let pin=menu.addItem(withTitle:"保持展开",action:#selector(toggleAlways),keyEquivalent:"");pin.target=self;pin.state=always ? .on : .off
        let reset=menu.addItem(withTitle:"恢复默认位置",action:#selector(resetPosition),keyEquivalent:"");reset.target=self
        let hint=NSMenuItem(title:"拖动竖条或图标可上下调整位置",action:nil,keyEquivalent:"");hint.isEnabled=false;menu.addItem(hint)
        menu.delegate=self;NSMenu.popUpContextMenu(menu,with:event,for:rail.isVisible ? rail.contentView! : grip)
    }
    @objc func toggleCompact(){UserDefaults.standard.set(!compact,forKey:"edgeDockCompact");layout();place();lastUI = .distantPast;refresh()}
    @objc func resetPosition(){UserDefaults.standard.removeObject(forKey:"edgeDockPosition");UserDefaults.standard.removeObject(forKey:"edgeDockDisplay");place()}
    @objc private func switchMeetingMode(){probe?.switchToPortableMeetingMode()}
    private func tick(){
        guard enabled,probe?.controlPanel?.window.isVisible != true else{hideAll();if enabled{scheduleTracking(active:false)};return};if menuTracking>0 || Date().timeIntervalSince(lastDrag)<0.25 {return}
        let point=NSEvent.mouseLocation,inWake=handle.frame.insetBy(dx:-14,dy:-10).intersection(screen?.visibleFrame ?? handle.frame).contains(point)
        let inRail=rail.isVisible && rail.frame.insetBy(dx:-6,dy:-6).contains(point),inCard=card.isVisible && card.frame.insetBy(dx:-12,dy:-8).contains(point)
        let inCorridor=card.isVisible && NSRect(x:card.frame.maxX,y:card.frame.minY,width:rail.frame.minX-card.frame.maxX,height:card.frame.height).contains(point)
        _=intent.tick(inside:inWake || inRail || inCard || inCorridor,now:Date());apply()
        if inRail {let item=rail.convertPoint(fromScreen:point).y>=rail.frame.height/2 ? 0 : 1;if item != hoverItem {hoverItem=item;refresh()};if !card.isVisible {card.orderFrontRegardless()}}
        else if !inCard && !inCorridor && !intent.revealed {card.orderOut(nil);hoverItem=nil}
        if Date().timeIntervalSince(lastUI)>1 {refresh();lastUI=Date()}
        scheduleTracking(active:intent.revealed || inWake || inRail || inCard || inCorridor)
    }
    private func apply(){if intent.revealed || always {if handle.isVisible{handle.orderOut(nil)};if !rail.isVisible {rail.orderFrontRegardless()}} else {if rail.isVisible{rail.orderOut(nil)};if card.isVisible{card.orderOut(nil)};if !handle.isVisible {handle.orderFrontRegardless()}}}
    func refresh(){
        guard let probe=probe,menuTracking==0 else{return};battery.stringValue=probe.batteryLevel.map{(probe.currentBatteryPower?.info.powerType == 1 ? "⚡" : "")+"\($0)%"} ?? "—";quota.stringValue=probe.codexQuota.summary
        grip.batteryText=battery.stringValue+(probe.batteryIsCached && probe.batteryLevel != nil ? "*" : "");grip.quotaText=quota.stringValue
        let connected=SystemBattery.device()?.isConnected()==true,recording=probe.currentRecording==true
        grip.batteryRemaining=connected && !probe.batteryIsCached ? probe.batteryLevel.map{Double($0)} : nil
        grip.quotaRemaining=probe.codexQuota.snapshot?.stale()==false ? probe.codexQuota.snapshot?.windows.first?.remaining : nil;let artwork="\(grip.batteryText)|\(grip.quotaText)|\(grip.batteryRemaining ?? -1)|\(grip.quotaRemaining ?? -1)"
        if artwork != lastArtwork{lastArtwork=artwork;grip.needsDisplay=true}
        grip.setAccessibilityLabel("Mic 电量 \(grip.batteryText)，\(probe.chargingLabel)，Codex 剩余额度 \(grip.quotaText)。上段为电量，下段为额度；悬停展开，上下拖动调整位置。灰色表示未知或过期；星号表示缓存值。")
        if ring.remaining != probe.codexQuota.snapshot?.windows.first?.remaining{ring.remaining=probe.codexQuota.snapshot?.windows.first?.remaining;ring.needsDisplay=true}
        if device.connected != connected || device.recording != recording{device.connected=connected;device.recording=recording;device.needsDisplay=true}
        let path=UserDefaults.standard.string(forKey:"lastVerifiedWallpaperPNG");if path != previewPath {previewPath=path;device.preview=path.flatMap{NSImage(contentsOfFile:$0)};device.needsDisplay=true}
        guard card.isVisible || hoverItem != nil else{return}
        let isQuota=hoverItem==1
        for view in [input,output,inputLabel,outputLabel] {view.isHidden=isQuota}
        title.stringValue=isQuota ? "Codex" : "Mic Pro";connection.stringValue=isQuota ? (probe.codexQuota.snapshot == nil ? (probe.codexQuota.reading ? "读取中" : "未连接") : probe.codexQuota.snapshot?.stale()==true ? "已过期" : "真实额度") : probe.handoffSuppressed ? (UserDefaults.standard.bool(forKey:"meetingModeRequested") ? "模式待确认" : "已暂停连接") : probe.dockConnectRequested ? "正在连接" : device.connected ? "已连接" : "未连接"
        charging.isHidden=isQuota;charging.stringValue=probe.chargingLabel;charging.textColor=probe.currentBatteryPower?.info.powerType == 1 ? MicStyle.green : MicStyle.muted;charging.toolTip=probe.chargingTooltip
        value.stringValue=isQuota ? probe.codexQuota.summary : (probe.batteryLevel.map{"\($0)%"} ?? "—");open.title=isQuota ? "额度详情" : device.connected ? "设备详情" : probe.dockConnectRequested ? "正在连接…" : "连接 Mic Pro 蓝牙";open.isEnabled=isQuota || !probe.dockConnectRequested
        let ch:CGFloat=compact ? 294 : 352,cw:CGFloat=compact ? 256 : 284
        details.frame=isQuota ? NSRect(x:16,y:90,width:cw-32,height:ch-190) : NSRect(x:16,y:ch-144,width:cw-32,height:52)
        disconnect.title=probe.meetingModeSession != nil ? "正在切换…" : "切到腾讯会议内录"
        disconnect.isHidden=isQuota || !DeviceConfig.experimentalFeaturesEnabled || !device.connected;disconnect.isEnabled = !probe.deviceTransactionBusy && probe.currentRecording != true
        disconnect.toolTip=probe.currentRecording == true ? "请先停止内录；不会自动停止录音" : "切换腾讯会议内录模式并断开Mac，不启动录音。返回Mac可能需三按电源键；保留腾讯绑定和原录音"
        if isQuota {details.stringValue=probe.codexQuota.detail;freshness.stringValue="账户额度 · 只读，不运行模型"}
        else{let power=probe.powerStrings();details.stringValue=power.activity+"\n"+power.recording;freshness.stringValue=probe.dockConnectRequested ? "正在尝试连接，请稍候" : !device.connected ? (probe.lastActionSummary ?? "点击 Mic 图标或下方按钮连接") : probe.batteryIsCached ? "电量为上次读取 · 等待更新" : "设备 / macOS 报告值";MicStyle.configureRoutes([input,output]);input.menu?.delegate=self;output.menu?.delegate=self;input.isEnabled = !probe.deviceTransactionBusy;output.isEnabled=input.isEnabled
            if probe.meetingModeSession != nil{freshness.stringValue="正在检查设置；不自动开始录音"}
            else if UserDefaults.standard.bool(forKey:"meetingModeRequested"),!device.connected{details.stringValue="腾讯会议模式请求已发送 · 待设备确认\n长按录音键开始/停止；回Mac需三按电源键";freshness.stringValue="保留绑定与原录音 · 不自动重试"}
            else if let message=probe.lastActionSummary{freshness.stringValue=message}
            freshness.toolTip=probe.lastActionSummary ?? disconnect.toolTip
        }
    }
    @objc private func openDetails(){if hoverItem==1 {probe?.showCodexPanel()} else {probe?.handleDockMicClick()}}
    @objc func toggleEnabled(){UserDefaults.standard.set(!enabled,forKey:"edgeDockEnabled");start()}
    @objc func toggleAlways(){UserDefaults.standard.set(!always,forKey:"edgeDockAlwaysVisible");tick()}
}
extension Probe {
    @objc func handleDockMicClick(){
        switch DockMicAction.resolve(connected:SystemBattery.device()?.isConnected()==true,busy:deviceTransactionBusy,paired:SystemBattery.device() != nil){
        case .showDetails:showDevicePanel()
        case .busy:lastActionSummary="当前设备操作进行中，请稍候";edgeDock?.refresh()
        case .needsPairing:lastActionSummary="未找到已配对 Mic Pro，请先在系统蓝牙设置配对";edgeDock?.refresh();showDevicePanel()
        case .connect:dockConnectRequested=true;returnDeviceToMac(id:nil);edgeDock?.refresh()
        }
    }
    @objc func showDevicePanel(){showControlPanel();controlPanel?.selectTab(1)}
    @objc func showCodexPanel(){showControlPanel();controlPanel?.selectTab(3)}
}
