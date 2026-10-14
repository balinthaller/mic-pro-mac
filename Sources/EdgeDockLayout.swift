import Foundation
import CoreGraphics

/// Persistent position is relative to usable screen space, so changing resolution stays safe.
enum EdgeDockLayout {
    static func fraction(centerY: CGFloat, in area: CGRect) -> Double {
        guard area.height>0 else{return 0.6}
        return Double(min(1,max(0,(centerY-area.minY)/area.height)))
    }
    static func frame(in area: CGRect, size: CGSize, fraction: Double) -> CGRect {
        let width=min(size.width,max(1,area.width)),height=min(size.height,max(1,area.height))
        let f=fraction.isFinite ? min(1,max(0,fraction)) : 0.6
        let y=min(area.maxY-height,max(area.minY,area.minY+area.height*f-height/2))
        return CGRect(x:area.maxX-width,y:y,width:width,height:height)
    }
}
