import Foundation
import CoreGraphics


/// Pure window policy; opening UI never changes device ownership or recording.
enum SidebarPresentation {
    static func frame(in visible: CGRect) -> CGRect {
        let width = min(400, max(1, visible.width - 24))
        let height = min(860, max(1, visible.height - 24))
        return CGRect(x: visible.maxX - width - min(12, max(0, visible.width - width)),
                      y: visible.maxY - height - min(12, max(0, visible.height - height)),
                      width: width, height: height)
    }
    static func restore(pinned: Bool, wasVisible: Bool) -> Bool { pinned && wasVisible }
}
