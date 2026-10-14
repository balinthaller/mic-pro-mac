import AppKit

final class MenuPopover {
    let popover=NSPopover()
    let device=MicDeviceView(frame:NSRect(x:15,y:222,width:76,height:79))
    let connection=NSTextField(labelWithString:"")
    let battery=NSTextField(labelWithString:"")
    let charging=NSTextField(labelWithString:"")
    let activity=NSTextField(labelWithString:"")
    let recording=NSTextField(labelWithString:"")
    let feedback=NSTextField(wrappingLabelWithString:"")
    let input=NSPopUpButton(),output=NSPopUpButton()
    let codex=CodexIconButton()
    let expand: NSButton
    var previewPath: String?
    init(probe: Probe?) {
        let controller=NSViewController();controller.view=MicSurface(frame:NSRect(x:0,y:0,width:336,height:320));let root=controller.view
        root.wantsLayer=true;root.layer?.backgroundColor=MicStyle.paper.cgColor
        root.addSubview(device);MicStyle.label("Mic Pro",in:root,frame:NSRect(x:102,y:273,width:120,height:25),size:18,weight:.semibold)
        battery.frame=NSRect(x:239,y:269,width:77,height:31);battery.font = .monospacedDigitSystemFont(ofSize:22,weight:.medium);root.addSubview(battery)
        connection.frame=NSRect(x:103,y:249,width:122,height:20);connection.font = .systemFont(ofSize:11);root.addSubview(connection)
        charging.frame=NSRect(x:227,y:250,width:91,height:18);charging.font = .systemFont(ofSize:10,weight:.medium);root.addSubview(charging)
        recording.frame=NSRect(x:103,y:226,width:211,height:20);recording.font = .systemFont(ofSize:10);recording.textColor=MicStyle.muted;root.addSubview(recording)
        codex.frame=NSRect(x:17,y:181,width:302,height:36);codex.bezelStyle = .rounded;codex.font = .systemFont(ofSize:12);codex.target=probe;codex.action=#selector(Probe.showCodexPanel);root.addSubview(codex)
        activity.frame=NSRect(x:22,y:155,width:292,height:19);activity.font = .systemFont(ofSize:10);activity.textColor=MicStyle.muted;root.addSubview(activity)
        for (popup,y,tag,title) in [(input,115.0,0,"输入"),(output,83.0,1,"输出")] {
            MicStyle.label(title,in:root,frame:NSRect(x:22,y:y+3,width:33,height:18),size:11,muted:true)
            popup.frame=NSRect(x:61,y:y,width:252,height:25);popup.font = .systemFont(ofSize:11);popup.target=probe;popup.action=#selector(Probe.selectPanelAudio(_:));popup.tag=tag;popup.setAccessibilityLabel(title+"设备");root.addSubview(popup)
        }
        expand=MicStyle.button("展开控制面板  ⌃⌥M",in:root,frame:NSRect(x:17,y:42,width:302,height:30),target:probe,action:#selector(Probe.showControlPanel),symbol:"sidebar.right")
        feedback.frame=NSRect(x:22,y:8,width:292,height:28);feedback.font = .systemFont(ofSize:10);feedback.textColor=MicStyle.muted;root.addSubview(feedback)
        popover.contentViewController=controller;popover.behavior = .transient;popover.appearance=nil
    }
    func close(){popover.performClose(nil)}
    func update(probe: Probe) {
        guard popover.isShown else{return}
        let connected=SystemBattery.device()?.isConnected() == true,usb=probe.connectedUSBVolumes().first,idle = !probe.deviceTransactionBusy
        battery.stringValue=probe.batteryLevel.map{"\($0)%"} ?? "—";battery.toolTip=probe.batteryIsCached ? "上次读取的电量" : "设备/macOS报告值"
        charging.stringValue=probe.chargingLabel;charging.textColor=probe.currentBatteryPower?.info.powerType == 1 ? MicStyle.green : MicStyle.muted;charging.toolTip=probe.chargingTooltip
        connection.stringValue=probe.handoffSuppressed ? "本应用已暂停连接" : usb.map{"USB · "+$0.root.lastPathComponent} ?? (connected ? "蓝牙已连接" : "设备未连接");connection.textColor=connected || usb != nil ? MicStyle.green : MicStyle.muted
        let text=probe.powerStrings()
        recording.stringValue=text.recording
        activity.stringValue=text.activity.replacingOccurrences(of:"电脑收音：未检测到软件正在采集",with:"当前没有软件在收音")
        codex.title="Codex · 剩余 "+probe.codexQuota.summary
        feedback.stringValue=probe.panelShortcut?.error ?? probe.recordingTransferSnapshot()?["phase"] as? String ?? (idle ? probe.lastActionSummary ?? "设备设置与录音文件在控制面板中" : "设备操作进行中…")
        device.connected=connected;device.recording=probe.currentRecording == true
        let path=UserDefaults.standard.string(forKey:"lastVerifiedWallpaperPNG")
        if previewPath != path {previewPath=path;device.preview=path.flatMap{NSImage(contentsOfFile:$0)}}
        device.needsDisplay=true
        expand.title="展开控制面板"+(probe.panelShortcut?.selection == 3 ? "" : "  "+(probe.panelShortcut?.label ?? "⌃⌥M"))
        MicStyle.configureRoutes([input,output]);input.isEnabled=idle;output.isEnabled=idle
    }
}
extension Probe {
    @objc func toggleMenuPopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {showMoreMenu(statusItem.button!);return}
        if menuPopover == nil {menuPopover=MenuPopover(probe:self)}
        guard let button=statusItem.button,let panel=menuPopover else{return}
        if panel.popover.isShown {panel.close()} else{panel.popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY);panel.update(probe:self)}
    }
    @objc func showMoreMenu(_ sender: NSButton) {
        let menu=NSMenu();menu.autoenablesItems=false;buildCompactMenu(menu)
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)
    }
}
