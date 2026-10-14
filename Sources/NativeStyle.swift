import AppKit

enum MicStyle {
    static let paper=NSColor(name:nil){appearance in appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? NSColor(calibratedRed:0.14,green:0.18,blue:0.16,alpha:1) : NSColor(calibratedRed:0.980,green:0.984,blue:0.976,alpha:1)}
    static let ink=NSColor.labelColor
    static let muted=NSColor.secondaryLabelColor
    static let line=NSColor.separatorColor
    static let green=NSColor(name:nil){appearance in appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? NSColor(calibratedRed:0.64,green:0.83,blue:0.70,alpha:1) : NSColor(calibratedRed:0.19,green:0.46,blue:0.33,alpha:1)}
    @discardableResult static func label(_ text: String,in view: NSView,frame: NSRect,size: CGFloat=13,weight: NSFont.Weight = .regular,muted: Bool=false) -> NSTextField {
        let label=NSTextField(labelWithString:text);label.frame=frame;label.font = .systemFont(ofSize:size,weight:weight);label.textColor=muted ? self.muted : ink;view.addSubview(label);return label
    }
    @discardableResult static func card(in view: NSView,frame: NSRect) -> NSView {
        let card=MicSurface(frame:frame);card.wantsLayer=true;card.layer?.cornerRadius=14;card.layer?.borderWidth=1;card.layer?.borderColor=line.cgColor;view.addSubview(card);return card
    }
    @discardableResult static func button(_ title: String,in view: NSView,frame: NSRect,target: AnyObject?,action: Selector,symbol: String?=nil,primary: Bool=false) -> NSButton {
        let button=NSButton(title:title,target:target,action:action);button.frame=frame;button.bezelStyle = .rounded;button.font = .systemFont(ofSize:13,weight:.medium)
        if let symbol=symbol { button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);button.imagePosition = .imageLeading }
        if primary { button.bezelColor=green;button.contentTintColor = .white }
        view.addSubview(button);return button
    }
    static func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount:Int64(count),countStyle:.file) }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite,seconds >= 0 else{return "—"};if seconds > 0 && seconds < 1 {return String(format:"%.1f秒",seconds)};let n=Int(seconds)
        return n >= 3600 ? String(format:"%d:%02d:%02d",n/3600,(n/60)%60,n%60) : String(format:"%d:%02d",n/60,n%60)
    }
    static func configureRoutes(_ popups: [NSPopUpButton]) {
        guard let devices=try? AudioRouting.devices() else{return}
        for popup in popups {
            let direction: AudioDirection=popup.tag == 0 ? .input : .output
            let suitable=devices.filter{direction == .input ? $0.inputChannels>0 : $0.outputChannels>0}
            let old=popup.itemArray.map{$0.representedObject as? String ?? ""}
            if old != suitable.map({$0.uid}) { popup.removeAllItems();for d in suitable { popup.addItem(withTitle:d.name);popup.lastItem?.representedObject=d.uid } }
            if let current=try? AudioRouting.current(direction),let d=suitable.first(where:{$0.id == current}),let row=popup.itemArray.first(where:{$0.representedObject as? String == d.uid}) { popup.select(row) }
        }
    }
}

/// Layer-backed materials must resolve colors again when macOS appearance changes.
class MicSurface: NSView {
    var bordered=false
    override init(frame: NSRect){super.init(frame:frame);wantsLayer=true;refreshColors()}
    required init?(coder: NSCoder){super.init(coder:coder);wantsLayer=true;refreshColors()}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();refreshColors()}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();refreshColors()}
    func refreshColors(){effectiveAppearance.performAsCurrentDrawingAppearance {layer?.backgroundColor=MicStyle.paper.withAlphaComponent(0.97).cgColor;layer?.borderColor=MicStyle.line.cgColor};needsDisplay=true}
}
