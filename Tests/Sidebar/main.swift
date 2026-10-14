import Foundation
import CoreGraphics

func check(_ ok: Bool, _ message: String) { if !ok { fatalError(message) } }
for screen in [CGRect(x:0,y:25,width:1440,height:875), CGRect(x:-1920,y:-300,width:1920,height:1080), CGRect(x:0,y:0,width:800,height:500), CGRect(x:0,y:0,width:15,height:15)] {
    let panel = SidebarPresentation.frame(in:screen)
    check(panel.width > 0 && panel.height > 0, "positive panel")
    check(screen.contains(panel), "panel stays in usable screen")
    check(panel.maxX <= screen.maxX && screen.maxX-panel.maxX <= 12, "right aligned")
}
check(!SidebarPresentation.restore(pinned:false,wasVisible:true), "temporary panels do not reopen")
check(!SidebarPresentation.restore(pinned:true,wasVisible:false), "hidden pinned panel stays hidden")
check(SidebarPresentation.restore(pinned:true,wasVisible:true), "visible pinned panel restores")
print("Sidebar geometry and restore checks passed")
let start=Date(timeIntervalSince1970:1000)
var dock=EdgeDockIntent()
check(!dock.tick(inside:true,now:start),"passing pointer does not open")
check(!dock.tick(inside:true,now:start.addingTimeInterval(0.1)),"wait for intent")
check(dock.tick(inside:true,now:start.addingTimeInterval(0.15)),"dwell reveals")
check(dock.tick(inside:false,now:start.addingTimeInterval(0.2)),"gap crossing keeps dock")
check(dock.tick(inside:true,now:start.addingTimeInterval(0.3)),"reentry cancels hide")
check(dock.tick(inside:false,now:start.addingTimeInterval(0.4)),"exit grace")
check(!dock.tick(inside:false,now:start.addingTimeInterval(0.73)),"leave hides")
dock.reveal();check(dock.revealed,"click reveals immediately");dock.reset();check(!dock.revealed,"disable resets")
print("Edge dock dwell, reentry and hide grace checks passed")
assert(DockMicAction.resolve(connected:true,busy:false,paired:true) == .showDetails)
assert(DockMicAction.resolve(connected:true,busy:true,paired:true) == .showDetails)
assert(DockMicAction.resolve(connected:false,busy:true,paired:true) == .busy)
assert(DockMicAction.resolve(connected:false,busy:false,paired:true) == .connect)
assert(DockMicAction.resolve(connected:false,busy:false,paired:false) == .needsPairing)
print("PASS dock Mic connected/detail, disconnected/connect, busy repeat guard and missing pairing")
for area in [CGRect(x:0,y:25,width:1440,height:875),CGRect(x:-1920,y:-300,width:1920,height:1080),CGRect(x:0,y:0,width:800,height:500)] {
    for fraction in [-2.0,0,0.3,0.6,1,3,Double.nan] {
        for size in [CGSize(width:64,height:210),CGSize(width:46,height:158),CGSize(width:8,height:98),CGSize(width:8,height:124)] {
            let frame=EdgeDockLayout.frame(in:area,size:size,fraction:fraction)
            check(area.contains(frame),"drag/restore remains within available screen")
            check(frame.maxX==area.maxX,"dock stays flush right")
        }
    }
    let fraction=EdgeDockLayout.fraction(centerY:area.midY,in:area)
    check(abs(fraction-0.5)<0.00001,"relative position survives display origin")
    check(EdgeDockLayout.frame(in:area,size:CGSize(width:46,height:158),fraction:fraction).midY==area.midY,"compact mode preserves center")
}
print("PASS drag clamping, negative-screen coordinates, compact center and invalid saved fraction")
