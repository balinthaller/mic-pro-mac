import AppKit
// Public preview uses a system glyph; no copied vendor artwork is distributed.
enum CodexIcon {
 static func image(for appearance:NSAppearance)->NSImage? {NSImage(systemSymbolName:"chart.bar",accessibilityDescription:"Codex quota")}
}
final class CodexIconButton: NSButton {
 override func viewDidMoveToWindow(){super.viewDidMoveToWindow();image=CodexIcon.image(for:effectiveAppearance);imagePosition = .imageLeading}
}
