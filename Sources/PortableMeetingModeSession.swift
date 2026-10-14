import AppKit
import CoreBluetooth
import IOBluetooth

/// Product transport for the previously verified 1020 command. Never binds, records or deletes.
final class PortableMeetingModeSession: NSObject, IOBluetoothRFCOMMChannelDelegate {
    weak var probe: Probe?
    let device: IOBluetoothDevice
    let plan=PortableMeetingModePlan()
    let started=Date(),token=UUID().uuidString
    var channel: IOBluetoothRFCOMMChannel?,timer: Timer?,requestAt: Date?
    var phase="clearing",stageAt=Date(),stream=FrameStream()
    var classicCloseCompleted=false
    var attempted=false,written=false,finished=false,firmware:String?,error:String?
    let versionMessage:UInt16=0x700
    init(probe:Probe,device:IOBluetoothDevice){self.probe=probe;self.device=device;super.init()}
    func start(){
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in self?.tick()};tick()
    }
    private func journal() -> Bool {
        guard probe != nil else{return false}
        let folder=URL(fileURLWithPath:projectRoot+"/logs/meeting-mode-switch")
        let data:[String:Any]=["id":token,"at":ISO8601DateFormatter().string(from:Date()),"phase":phase,"firmware":firmware as Any? ?? NSNull(),"attempted":attempted,"command_written":written,"actual_mode_verified":false,"binding_write_sent":false,"record_start_stop_sent":false,"file_commands_sent":false,"baseline_common":plan.baselineCommon?.base64EncodedString() as Any? ?? NSNull(),"baseline_more":plan.baselineMore?.base64EncodedString() as Any? ?? NSNull(),"baseline_attributes":plan.baselineAttributes?.base64EncodedString() as Any? ?? NSNull(),"error":error as Any? ?? NSNull()]
        do{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent(token+".json"),options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:folder.appendingPathComponent(token+".json").path);return true}catch{return false}
    }
    private func note(_ text:String){probe?.log("腾讯会议模式："+text)}
    private func open(){
        phase="opening";stageAt=Date()
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            guard let self=self else{return};var opened:IOBluetoothRFCOMMChannel?
            let result=self.device.openRFCOMMChannelAsync(&opened,withChannelID:10,delegate:self)
            DispatchQueue.main.async{if self.finished{_=opened?.close();return};if self.channel==nil{self.channel=opened};if result != 0{self.fail("设置通道连接失败，未切换模式")}}
        }
    }
    func rfcommChannelOpenComplete(_ channel:IOBluetoothRFCOMMChannel!,status:IOReturn){
        DispatchQueue.main.async{[weak self] in
            guard let self=self,!self.finished,self.phase=="opening" else{return}
            guard status==0 else{self.fail("设置通道未成功打开，未切换模式");return}
            self.channel=channel;self.phase="version"
            self.send(wallpaperFrame(0x1001,Data([UInt8(self.versionMessage & 255),UInt8(self.versionMessage>>8)])))
        }
    }
    private func send(_ data:Data){
        guard !finished,let channel=channel,data.count>=11 else{return}
        let command=little16(data,3)
        guard [UInt16(0x1001),0x1009,0x100d,0x1014,0x1020].contains(command) else{fail("命令保护拒绝请求");return}
        if command==0x1020 {
            guard !attempted,plan.modeRequestWritten,PowerMonitor.usage()["mic_input_running"] as? Bool != true else{fail("请先停止电脑语音输入；尚未切换模式");return}
            phase="mode-request";guard journal() else{fail("无法保存设置基线，未切换模式");return}
            // Persist before the one-shot send; even an ambiguous write must not be retried/reconnected.
            attempted=true
            guard journal() else{attempted=false;fail("无法保存请求记录，未切换模式");return}
            if let probe=probe{_=probe.handoffState.beginRelease(busy:false);probe.persistHandoffIntent();UserDefaults.standard.set(true,forKey:"meetingModeRequested")}
        }
        requestAt=Date();var bytes=[UInt8](data)
        let result=bytes.withUnsafeMutableBytes{channel.writeSync($0.baseAddress,length:UInt16($0.count))}
        if command==0x1020{written=result==0;_=journal()}
        note(String(format:"TX %04X result=%d",command,result))
        if result != 0{fail(attempted ? "模式请求结果未知，未自动重试" : "设置读取发送失败，未切换模式")}
    }
    func rfcommChannelData(_ channel:IOBluetoothRFCOMMChannel!,data pointer:UnsafeMutableRawPointer!,length count:Int){
        let bytes=Data(bytes:pointer,count:count)
        DispatchQueue.main.async{[weak self] in
            guard let self=self,!self.finished,!(["closing","releasing"].contains(self.phase)) else{return}
            for frame in self.stream.append(bytes){
                if self.phase=="version" {
                    guard frame.command==0x1001,frame.sequence>>14==0,frame.payload.count>=3,little16(frame.payload,0)==self.versionMessage else{continue}
                    let body=Data(frame.payload.dropFirst(3));self.requestAt=nil
                    guard frame.payload[2]==0,body.count==49,body[48]==0,String(decoding:body[32..<48].prefix(while:{$0 != 0}),as:UTF8.self).hasSuffix(DeviceConfig.serialSuffix) else{self.fail("设备身份或固件回复不匹配");return}
                    self.firmware=String(decoding:body[16..<32].prefix(while:{$0 != 0}),as:UTF8.self)
                    guard ["2.0.2.4","V2.0.2.4","v2.0.2.4"].contains(self.firmware ?? "") else{self.fail("仅支持已验证固件2.0.2.4，未切换模式");return}
                    self.phase="reading";self.drive();continue
                }
                let responses=self.plan.responses;self.plan.consume(frame)
                if self.plan.responses != responses{self.requestAt=nil;self.drive()}
            }
        }
    }
    private func drive(){
        guard !finished else{return}
        if plan.state == .failed{fail("未完成切换："+(plan.error ?? "设置保护检查失败"));return}
        if plan.awaitingConfirmation{fail("请单按设备电源键确认授权，再点击切换；尚未发送模式请求");return}
        if plan.state == .baselineReady {
            guard journal(),plan.authorizeModeRequest() else{fail("设置基线未保存，未切换模式");return}
        }
        if plan.state == .settling{return}
        if plan.state == .readyToDisconnect{close();return}
        if let data=plan.nextRequest(){send(data)}
    }
    private func tick(){
        guard !finished else{return}
        if phase=="clearing" {
            if probe?.peripheral==nil{open()}else if Date().timeIntervalSince(started)>10{fail("旧控制通道未释放，未切换模式")};return
        }
        if phase=="closing"{if Date().timeIntervalSince(stageAt)>3{release()};return}
        if phase=="releasing"{
            if classicCloseCompleted,!device.isConnected(){finish();return}
            if Date().timeIntervalSince(stageAt)>10{error=error ?? "Mac断开尚未确认";finish()};return
        }
        if Date().timeIntervalSince(started)>35{fail(attempted ? "请求超时，模式状态待确认；未重试" : "读取超时，未切换模式");return}
        if phase=="opening",Date().timeIntervalSince(stageAt)>10{fail("控制通道打开超时，未切换模式");return}
        if let at=requestAt,Date().timeIntervalSince(at)>3{requestAt=nil;plan.timeout();fail(attempted ? "模式请求已发出，设备状态待确认；未重试" : "设置读取超时，未切换模式");return}
        if plan.state == .settling,plan.advanceAfterSettle(){drive()}
    }
    private func fail(_ text:String){guard !finished else{return};error=text;note(text);close()}
    private func close(){
        guard !finished,!(["closing","releasing"].contains(phase)) else{return}
        phase="closing";stageAt=Date();requestAt=nil
        if let channel=channel{if channel.close() != 0{release()}}else{release()}
    }
    func rfcommChannelClosed(_ channel:IOBluetoothRFCOMMChannel!){
        DispatchQueue.main.async{[weak self] in
            guard let self=self,!self.finished else{return};self.channel=nil
            if !self.attempted,self.phase != "closing"{self.error=self.error ?? "读取时通道断开，未切换模式"}
            self.release()
        }
    }
    private func release(){
        guard !finished,phase != "releasing" else{return}
        if !attempted{finish();return}
        phase="releasing";stageAt=Date()
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            guard let self=self else{return};let result=self.device.closeConnection()
            DispatchQueue.main.async{self.classicCloseCompleted=true;self.note("Mac释放返回码=\(result)")}
        }
    }
    private func finish(){
        guard !finished else{return};finished=true;timer?.invalidate();timer=nil
        if let probe=probe{
            if attempted{_=probe.handoffState.observeRelease(classicConnected:device.isConnected(),controlConnected:false,timedOut:true)}
            phase="finished";_=journal()
            let text=written ? "腾讯会议模式请求已发送 · \(error.map{$0+"。"} ?? "请看设备确认。")\(device.isConnected() ? "Mac断开未确认。" : "Mac已断开。")长按录音键开始/停止；返回Mac可能需三按电源键。" : error ?? "模式切换未完成"
            probe.lastActionSummary=text;note(text)
            if probe.meetingModeSession === self{probe.meetingModeSession=nil;probe.bluetoothOperation=false}
            probe.refreshBatteryDisplay();probe.edgeDock?.refresh();probe.updatePowerUI()
        }
    }
    func cancel(){guard !finished else{return};error="应用退出，操作状态待确认";_=journal();timer?.invalidate();timer=nil;finished=true;_=channel?.close();channel=nil}
}

extension Probe {
    @objc func switchToPortableMeetingMode(){
        guard DeviceConfig.experimentalFeaturesEnabled else {lastActionSummary="实验性模式切换默认关闭";return}
        guard !deviceTransactionBusy else{lastActionSummary="当前设备操作进行中，请稍候";edgeDock?.refresh();return}
        guard currentRecording != true,PowerMonitor.usage()["mic_input_running"] as? Bool != true else{lastActionSummary="请先停止内录和电脑语音输入，再切换腾讯会议模式";edgeDock?.refresh();return}
        guard !handoffSuppressed,let device=SystemBattery.device(),device.isConnected(),let services=device.services as? [IOBluetoothSDPServiceRecord],services.contains(where:{var port:BluetoothRFCOMMChannelID=0;return $0.getRFCOMMChannelID(&port)==0 && port==10}) else{lastActionSummary="请先连接Mic Pro到Mac，再切换腾讯会议模式";edgeDock?.refresh();return}
        bluetoothOperation=true;controlWanted=false;central.stopScan();scanTimer?.invalidate();scanTimer=nil
        if let p=peripheral{central.cancelPeripheralConnection(p)}
        let session=PortableMeetingModeSession(probe:self,device:device);meetingModeSession=session
        lastActionSummary="正在读取保护设置，然后切到腾讯会议内录…";edgeDock?.refresh();session.start()
    }
}
