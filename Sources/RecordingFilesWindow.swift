import AppKit

final class RecordingFilesWindow: NSObject,NSTableViewDataSource,NSTableViewDelegate {
    weak var probe: Probe?
    let window: NSWindow
    let table=NSTableView()
    let tableScroll=NSScrollView()
    var embeddedView: NSView?
    let source=NSSegmentedControl(labels:["自动","蓝牙","USB"],trackingMode:.selectOne,target:nil,action:nil)
    let search=NSSearchField()
    let summary=NSTextField(labelWithString:"")
    let status=NSTextField(wrappingLabelWithString:"选择录音后下载，原文件保留在设备。")
    let metrics=NSTextField(labelWithString:"")
    let progress=NSProgressIndicator()
    let download=NSButton(title:"下载所选录音",target:nil,action:nil)
    let refresh=NSButton(title:"刷新",target:nil,action:nil)
    let reveal=NSButton(title:"显示文件",target:nil,action:nil)
    let cancelButton=NSButton(title:"取消",target:nil,action:nil)
    let chooseUSB=NSButton(title:"选择录音盘…",target:nil,action:nil)
    let empty=NSTextField(wrappingLabelWithString:"连接 Mic Pro 后刷新\n蓝牙或USB均可读取录音")
    var items=[[String:Any]]();var visibleItems=[[String:Any]]()
    var requestID: String?;var savedFile: String?;var selectedUSBRoot: String?
    var cancelRequested=false
    init(probe: Probe?) {
        self.probe=probe
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:920,height:620),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        super.init();window.title="Mic Pro · 内录文件";window.isReleasedWhenClosed=false;window.center();window.appearance=nil;window.backgroundColor=MicStyle.paper
        let root=window.contentView!
        MicStyle.label("内录文件",in:root,frame:NSRect(x:26,y:558,width:410,height:36),size:26,weight:.semibold)
        summary.frame=NSRect(x:28,y:529,width:728,height:23);summary.font = .systemFont(ofSize:12);summary.textColor=MicStyle.muted;summary.stringValue="自动优先使用已连接的USB录音盘";root.addSubview(summary)
        refresh.frame=NSRect(x:798,y:557,width:98,height:34);refresh.bezelStyle = .rounded;refresh.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:nil);refresh.imagePosition = .imageLeading;refresh.target=self;refresh.action=#selector(load);root.addSubview(refresh)
        source.frame=NSRect(x:24,y:487,width:268,height:30);source.selectedSegment=0;source.target=self;source.action=#selector(sourceChanged);root.addSubview(source)
        search.frame=NSRect(x:310,y:487,width:379,height:30);search.placeholderString="搜索文件名或日期";search.target=self;search.action=#selector(filter);search.sendsSearchStringImmediately=true;root.addSubview(search)
        chooseUSB.frame=NSRect(x:704,y:487,width:192,height:30);chooseUSB.bezelStyle = .rounded;chooseUSB.target=self;chooseUSB.action=#selector(pickUSB);root.addSubview(chooseUSB)
        for (id,title,width) in [("name","文件名",417.0),("duration","时长",100.0),("size","大小",152.0),("format","格式",70.0),("transport","通道",84.0)] {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=title;column.width=width;table.addTableColumn(column)
        }
        table.delegate=self;table.dataSource=self;table.rowHeight=36;table.allowsMultipleSelection=false;table.usesAlternatingRowBackgroundColors=true;table.backgroundColor = .white
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll=tableScroll;scroll.frame=NSRect(x:24,y:184,width:872,height:284);scroll.hasVerticalScroller=true;scroll.documentView=table;scroll.wantsLayer=true;scroll.layer?.cornerRadius=12;scroll.layer?.borderWidth=1;scroll.layer?.borderColor=MicStyle.line.cgColor;root.addSubview(scroll)
        empty.frame=NSRect(x:286,y:302,width:350,height:70);empty.alignment = .center;empty.font = .systemFont(ofSize:14);empty.textColor=MicStyle.muted;root.addSubview(empty)
        MicStyle.card(in:root,frame:NSRect(x:24,y:24,width:872,height:141))
        status.frame=NSRect(x:44,y:120,width:828,height:30);status.font = .systemFont(ofSize:13,weight:.medium);status.textColor=MicStyle.ink;root.addSubview(status)
        progress.frame=NSRect(x:44,y:100,width:828,height:7);progress.style = .bar;progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;root.addSubview(progress)
        metrics.frame=NSRect(x:44,y:73,width:828,height:23);metrics.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);metrics.textColor=MicStyle.muted;root.addSubview(metrics)
        for (button,x,width,selector) in [(reveal,40.0,124.0,#selector(showFile)),(cancelButton,604.0,110.0,#selector(cancel)),(download,726.0,150.0,#selector(fetch))] {
            button.target=self;button.action=selector;button.bezelStyle = .rounded;button.frame=NSRect(x:x,y:36,width:width,height:32);root.addSubview(button)
        }
        download.bezelColor=MicStyle.green;download.contentTintColor = .white
        download.isEnabled=false;reveal.isEnabled=false;cancelButton.isEnabled=false
    }
    func embeddedContent() -> NSView {
        if let view=embeddedView {return view}
        let view=window.contentView!;window.contentView=nil;embeddedView=view
        view.frame=NSRect(x:0,y:0,width:352,height:487)
        for child in view.subviews where type(of:child) == NSView.self {child.removeFromSuperview()}
        for label in view.subviews.compactMap({$0 as? NSTextField}) where label.stringValue == "内录文件" {label.isHidden=true}
        summary.frame=NSRect(x:1,y:453,width:350,height:30);summary.lineBreakMode = .byTruncatingMiddle
        source.frame=NSRect(x:0,y:413,width:211,height:30);refresh.frame=NSRect(x:261,y:413,width:91,height:30)
        search.frame=NSRect(x:0,y:373,width:352,height:30);chooseUSB.frame=NSRect(x:0,y:338,width:352,height:28)
        tableScroll.frame=NSRect(x:0,y:161,width:352,height:168)
        for column in table.tableColumns { switch column.identifier.rawValue {case "name":column.width=145;case "duration":column.width=61;case "size":column.width=90;case "format":column.width=46;default:column.isHidden=true} }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle;table.rowHeight=32
        empty.frame=NSRect(x:12,y:207,width:328,height:70)
        status.frame=NSRect(x:2,y:112,width:348,height:40);status.font = .systemFont(ofSize:11)
        progress.frame=NSRect(x:2,y:98,width:348,height:7)
        metrics.frame=NSRect(x:2,y:55,width:348,height:37);metrics.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular);metrics.maximumNumberOfLines=2;metrics.lineBreakMode = .byWordWrapping
        reveal.frame=NSRect(x:0,y:13,width:105,height:30);cancelButton.frame=NSRect(x:111,y:13,width:75,height:30);download.frame=NSRect(x:192,y:13,width:160,height:30);download.title="导出所选录音"
        return view
    }
    func show(){if embeddedView != nil {probe?.showRecordingFiles();return};window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);if items.isEmpty,requestID == nil {load()}}
    var transport: String { ["auto","bluetooth","usb"][max(0,source.selectedSegment)] }
    func numberOfRows(in tableView: NSTableView) -> Int {visibleItems.count}
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        let item=visibleItems[row];let value: String
        switch column?.identifier.rawValue {
        case "name":value=item["name"] as? String ?? "未知"
        case "duration":value=(item["duration_seconds"] as? NSNumber).map{MicStyle.time($0.doubleValue)} ?? (item["duration_raw"] as? NSNumber).map{MicStyle.time($0.doubleValue)} ?? "—"
        case "size":value=(item["file_bytes"] as? NSNumber).map{MicStyle.bytes($0.intValue)} ?? "下载时读取"
        case "format":value=item["format"] as? String ?? "OGG"
        case "transport":value=item["transport"] as? String == "usb" ? "USB" : "蓝牙"
        default:value=""
        }
        let label=NSTextField(labelWithString:value);label.font = .systemFont(ofSize:12);label.textColor=column?.identifier.rawValue == "name" ? MicStyle.ink : MicStyle.muted;label.lineBreakMode = .byTruncatingMiddle;return label
    }
    func tableViewSelectionDidChange(_ notification: Notification){download.isEnabled=requestID == nil && visibleItems.indices.contains(table.selectedRow)}
    @objc func sourceChanged(){load()}
    @objc func filter(){let query=search.stringValue.lowercased();visibleItems=items.filter{query.isEmpty || ($0["name"] as? String ?? "").lowercased().contains(query)};table.reloadData();empty.isHidden = !visibleItems.isEmpty;download.isEnabled=requestID == nil && visibleItems.indices.contains(table.selectedRow)}
    @objc func pickUSB(){
        let picker=NSOpenPanel();picker.canChooseDirectories=true;picker.canChooseFiles=false;picker.allowsMultipleSelection=false;picker.directoryURL=URL(fileURLWithPath:"/Volumes");picker.message="选择 Mic Pro 的录音盘，不会修改盘内文件。"
        guard picker.runModal() == .OK,let url=picker.url else{return}
        guard (try? USBRecordingStore(root:url)) != nil else{status.stringValue=TransferError.invalidRoot.localizedDescription;return}
        selectedUSBRoot=url.path;UserDefaults.standard.set(url.path,forKey:"recordingUSBRoot");source.selectedSegment=2;load()
    }
    @objc func load(){begin(item:nil)}
    @objc func fetch(){guard visibleItems.indices.contains(table.selectedRow) else{return};begin(item:visibleItems[table.selectedRow])}
    func begin(item: [String:Any]?) {
        guard requestID == nil,let probe=probe else{return}
        let id=UUID().uuidString;requestID=id;cancelRequested=false;setBusy(true);progress.doubleValue=0;progress.isIndeterminate=true;progress.startAnimation(nil)
        status.stringValue=item == nil ? "正在读取录音列表…" : "准备下载："+(item?["name"] as? String ?? "录音")
        metrics.stringValue=""
        if let item=item,item["transport"] as? String == "usb" {
            probe.startRecordingRequest(id:id,transport:"usb",usbRoot:item["usb_root"] as? String,relative:item["relative_path"] as? String)
        } else {probe.startRecordingRequest(id:id,fileID:(item?["file_id"] as? NSNumber)?.uint32Value,fragment:(item?["fragment_raw"] as? NSNumber)?.uint16Value,transport:item == nil ? transport : "bluetooth",usbRoot:selectedUSBRoot)}
    }
    func setBusy(_ value: Bool){refresh.isEnabled = !value;source.isEnabled = !value;chooseUSB.isEnabled = !value;download.isEnabled = !value && visibleItems.indices.contains(table.selectedRow);cancelButton.isEnabled=false}
    @objc func cancel(){guard let id=requestID,probe?.cancelRecordingTransfer(id) == true else{return};cancelRequested=true;cancelButton.isEnabled=false;status.stringValue="正在取消，原录音保留…"}
    func tick(){
        guard (window.isVisible || embeddedView?.window?.isVisible == true),let id=requestID,let snapshot=probe?.recordingTransferSnapshot(),snapshot["request_id"] as? String == id else{return}
        let total=(snapshot["total_bytes"] as? NSNumber)?.intValue ?? 0;let received=(snapshot["received_bytes"] as? NSNumber)?.intValue ?? 0
        let phase=snapshot["phase"] as? String ?? "正在传输"
        if !cancelRequested {status.stringValue=phase;cancelButton.isEnabled=snapshot["can_cancel"] as? Bool == true}
        if total > 0 {
            progress.stopAnimation(nil);progress.isIndeterminate=false;progress.doubleValue=min(1,Double(received)/Double(total))
            let rate=(snapshot["speed_bytes_per_second"] as? NSNumber)?.intValue ?? 0
            let eta=(snapshot["eta_seconds"] as? NSNumber)?.doubleValue
            metrics.stringValue=MicStyle.bytes(received)+" / "+MicStyle.bytes(total)+"  ·  "+MicStyle.bytes(rate)+"/s"+(phase.contains("校验") || phase.contains("确认") ? "  ·  校验完成后保存" : eta.map{"  ·  预计剩余 "+MicStyle.time($0)} ?? "")
        }
    }
    func updateProgress(id: String,found: Int,details: Int,scanning: Bool){guard requestID == id else{return};status.stringValue=scanning ? "扫描录音，已找到 \(found) 条…" : "读取文件信息 \(details)/\(found)…"}
    func receive(id: String,payload: [String:Any]) {
        guard requestID == id else{return};requestID=nil;cancelRequested=false;progress.stopAnimation(nil);progress.isIndeterminate=false;setBusy(false)
        if payload["ok"] as? Bool == true {
            if payload["action"] as? String == "recordings-list",let values=payload["items"] as? [[String:Any]] {
                items=values;filter();let usb=payload["transport"] as? String == "usb";let total=values.compactMap{($0["file_bytes"] as? NSNumber)?.intValue}.reduce(0,+)
                summary.stringValue=(usb ? "USB · "+((payload["usb_root"] as? String).map{URL(fileURLWithPath:$0).lastPathComponent} ?? "录音盘") : "蓝牙 · OGG录音索引")+"  ·  \(values.count) 条"+(usb ? "  ·  "+MicStyle.bytes(total) : "  ·  接USB可浏览WAV")
                status.stringValue="列表已更新，选择一条录音即可下载。";metrics.stringValue="";progress.doubleValue=0
            }
            if let path=payload["file"] as? String {savedFile=path;reveal.isEnabled=true;status.stringValue="下载完成，已校验。原录音保留在设备。";progress.doubleValue=1;metrics.stringValue=(payload["bytes"] as? NSNumber).map{MicStyle.bytes($0.intValue)} ?? ""}
        } else{status.stringValue=payload["error"] as? String ?? "操作未完成，请检查设备连接。"}
    }
    @objc func showFile(){if let path=savedFile{NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])}}
}
extension Probe {
    @objc func showRecordingFiles(){showControlPanel();controlPanel?.selectTab(2)}
}
