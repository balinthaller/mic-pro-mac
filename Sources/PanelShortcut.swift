import AppKit
import Carbon

/// Registers only a chosen shortcut; does not monitor keystrokes or need Accessibility access.
final class PanelShortcut {
    static let labels = ["⌃⌥M", "⌃⌥Space", "⌃⇧M", "停用"]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onToggle: (() -> Void)?
    private(set) var error: String?
    var selection: Int { min(3,max(0,UserDefaults.standard.integer(forKey:"sidebarShortcut"))) }
    var label: String { Self.labels[selection] }
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context=context, let event=event else{return OSStatus(eventNotHandledErr)}
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4d50524f, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<PanelShortcut>.fromOpaque(context).takeUnretainedValue().onToggle?()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { error = "快捷键事件注册失败（\(status)）" }
        else { register() }
    }
    func select(_ index: Int) { UserDefaults.standard.set(index,forKey:"sidebarShortcut"); register() }
    private func register() {
        if let key=hotKey { UnregisterEventHotKey(key); hotKey=nil }
        guard handler != nil else{return}
        error=nil;guard selection != 3 else{return}
        let key = selection == 1 ? UInt32(kVK_Space) : UInt32(kVK_ANSI_M)
        let modifiers = selection == 2 ? UInt32(controlKey | shiftKey) : UInt32(controlKey | optionKey)
        let status = RegisterEventHotKey(key,modifiers,EventHotKeyID(signature:0x4d50524f,id:1),GetApplicationEventTarget(),0,&hotKey)
        if status != noErr { error = "\(label) 无法注册（\(status)），请在更多设置更换快捷键" }
    }
    deinit { if let key=hotKey {UnregisterEventHotKey(key)};if let handler=handler {RemoveEventHandler(handler)} }
}
