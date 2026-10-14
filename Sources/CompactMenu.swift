import AppKit

extension Probe {
    func buildCompactMenu(_ menu: NSMenu) {
        refreshBatteryDisplay(); menu.removeAllItems()
        let header = NSMenuItem(title:"Mic Pro · " + (connectedUSBVolumes().first != nil ? "USB已连接" : primaryControlAvailable ? "控制就绪" : SystemBattery.device()?.isConnected() == true ? "已连接" : "未连接"),action:nil,keyEquivalent:"")
        header.isEnabled = false;menu.addItem(header)
        powerMenuLabels = [:];menu.addItem(.separator())
        let idle = !deviceTransactionBusy
        func action(_ title: String,_ selector: Selector,_ symbol: String,_ enabled: Bool = true) {
            let row = menu.addItem(withTitle:title,action:selector,keyEquivalent:"");row.target = self;row.isEnabled = enabled
            row.image = NSImage(systemSymbolName:symbol,accessibilityDescription:title)
        }
        action("打开控制面板…",#selector(showControlPanel),"slider.horizontal.3")
        menu.addItem(.separator());addAudioChoices(to:menu)
        let connected = SystemBattery.device()?.isConnected() == true
        action(handoffSuppressed ? "连接回 Mac" : "交给手机",#selector(toggleDeviceOwnership),"iphone",idle && SystemBattery.device() != nil)
        action(connected ? "断开麦克风" : "连接麦克风",#selector(toggleBluetooth),connected ? "link" : "link.badge.plus",idle && !handoffSuppressed && SystemBattery.device() != nil)
        menu.addItem(.separator())
        action("内录文件…",#selector(showRecordingFiles),"folder")
        action("电量与省电…",#selector(showPowerDashboard),"battery.100")
        action("备份当前壁纸",#selector(backupWallpaper),"square.and.arrow.down",idle && primaryControlAvailable)
        let advanced = NSMenuItem(title:"高级",action:nil,keyEquivalent:"");let submenu = NSMenu(title:"高级");submenu.autoenablesItems = false
        for (title,selector) in [("蓝牙诊断…",#selector(showDiagnostic)),("交互式音频测试…",#selector(showInteractiveTest)),("观察手机发现广播（60秒）",#selector(observeDiscoveryBroadcasts)),("系统蓝牙设置…",#selector(openBluetoothSettings))] {
            if !DeviceConfig.experimentalFeaturesEnabled && [#selector(showInteractiveTest),#selector(observeDiscoveryBroadcasts)].contains(selector) { continue }
            let row = submenu.addItem(withTitle:title,action:selector,keyEquivalent:"");row.target = self
        }
        let legacy = submenu.addItem(withTitle:"旧版设置连接（会释放音频）",action:#selector(toggleControlConnection),keyEquivalent:"");legacy.target = self;legacy.isEnabled = idle && !handoffSuppressed
        for (title,selector) in [("震动反馈开关",#selector(toggleVibration)),("LED整体开关",#selector(toggleLeds))] {
            let row = submenu.addItem(withTitle:title,action:selector,keyEquivalent:"");row.target = self;row.isEnabled = idle && authorized && moreSettings != nil
        }
        let tips=NSMenuItem(title:"设备提示",action:nil,keyEquivalent:"");let tipMenu=NSMenu();tipMenu.autoenablesItems=false
        for (title,selector) in [("震动一下",#selector(vibrateAndReconnect)),("灯光闪一下",#selector(blinkLights))] {let item=tipMenu.addItem(withTitle:title,action:selector,keyEquivalent:"");item.target=self;item.isEnabled=idle && primaryControlAvailable && peripheral == nil}
        tips.submenu=tipMenu;submenu.addItem(tips)
        advanced.submenu = submenu;menu.addItem(advanced);menu.addItem(.separator())
        let version = NSMenuItem(title:"Mic Pro "+AppVersion.version,action:nil,keyEquivalent:"");version.isEnabled = false;menu.addItem(version)
        let quit = menu.addItem(withTitle:"退出 Mic Pro",action:#selector(quitApp),keyEquivalent:"q");quit.target = self
    }
    func addAudioChoices(to menu: NSMenu) {
        guard let devices = try? AudioRouting.devices() else { return }
        for (direction,title,tag) in [(AudioDirection.input,"输入",0),(.output,"输出",1)] {
            let current = try? AudioRouting.current(direction)
            let selected = devices.first { $0.id == current }?.name ?? "未知"
            let parent = NSMenuItem(title:title + "：" + selected,action:nil,keyEquivalent:"")
            let choices = NSMenu(title:title)
            for device in devices where direction == .input ? device.inputChannels > 0 : device.outputChannels > 0 {
                let row = choices.addItem(withTitle:device.name,action:#selector(selectAudio(_:)),keyEquivalent:"");row.target = self;row.tag = tag;row.representedObject = device.uid;row.state = current == device.id ? .on : .off
            }
            parent.submenu = choices;menu.addItem(parent)
        }
    }
}
