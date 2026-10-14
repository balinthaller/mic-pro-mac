import AppKit
let projectRoot="/tmp/micpro-render-tests"
func check(_ x: Bool,_ message: String){if !x {fatalError(message)}}
var options=WallpaperRenderOptions()
let contain=wallpaperImageRect(size:NSSize(width:400,height:100),options:options)
check(abs(contain.width-240)<0.01 && abs(contain.height-60)<0.01,"contain preserves wide aspect")
options.fit = .cover
let cover=wallpaperImageRect(size:NSSize(width:400,height:100),options:options)
check(abs(cover.height-208)<0.01 && cover.width>240,"cover fills without distortion")
options.x=1;let shifted=wallpaperImageRect(size:NSSize(width:400,height:100),options:options)
check(abs(shifted.minX)<0.01,"crop reaches left edge without exposing background")
options.x = -1
check(abs(wallpaperImageRect(size:NSSize(width:400,height:100),options:options).maxX-240)<0.01,"opposite horizontal crop edge")
options.y = 1
check(abs(wallpaperImageRect(size:NSSize(width:100,height:400),options:options).minY-32)<0.01,"vertical crop reaches bottom edge")
options.y = -1
check(abs(wallpaperImageRect(size:NSSize(width:100,height:400),options:options).maxY-240)<0.01,"vertical crop reaches top edge")
let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:100,pixelsHigh:100,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:400,bitsPerPixel:32)!
for yy in 0..<100 {for xx in 0..<100 {var p=[xx*255/100,yy*255/100,120,xx<20 ? 0 : 255];rep.setPixel(&p,atX:xx,y:yy)}}
let image=NSImage(size:NSSize(width:100,height:100));image.addRepresentation(rep)
for dither in [false,true] {
 options=WallpaperRenderOptions();options.dither=dither
 let png=try! renderedWallpaper(image:image,options:options)
 check(try! decodedWallpaperPanel(png).count == 24960,"six-color opaque canonical panel with dither and alpha flattening")
 let parsed=NSBitmapImageRep(data:png)!
 for yy in 208..<240 {for xx in 0..<240 {var p=[Int](repeating:0,count:4);parsed.getPixel(&p,atX:xx,y:yy);check(Array(p.prefix(3))==wallpaperRGB[1],"padding band stays deterministic outside image/dither")}}
}
// Asymmetric source catches AppKit bottom-left vs PNG top-left inversions.
let asymmetric=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,pixelsHigh:208,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:960,bitsPerPixel:32)!
for yy in 0..<208 {for xx in 0..<240 {
 var p=(yy<104 ? wallpaperRGB[3] : wallpaperRGB[5])+[255]
 if xx<20 {p=[0,0,0,0]}
 asymmetric.setPixel(&p,atX:xx,y:yy)
}}
let asymmetricImage=NSImage(size:NSSize(width:240,height:208));asymmetricImage.addRepresentation(asymmetric)
options=WallpaperRenderOptions()
let canonical=try! renderedWallpaper(image:asymmetricImage,options:options)
let pixels=NSBitmapImageRep(data:canonical)!
func rgb(_ xx:Int,_ yy:Int)->[Int] {var p=[Int](repeating:0,count:4);pixels.getPixel(&p,atX:xx,y:yy);check(p[3]==255,"flattened opacity");return Array(p.prefix(3))}
check(rgb(120,0)==wallpaperRGB[3] && rgb(120,207)==wallpaperRGB[5],"PNG top 208 rows preserve source orientation")
check(rgb(5,100)==wallpaperRGB[1],"fully transparent source reveals selected background")
let panel=try! decodedWallpaperPanel(canonical)
check(panel[60]==0x33 && panel[207*120+60]==0x66,"uploaded panel top and bottom match rendered PNG")
// Preview crops the exact same 240x208 region from the canonical PNG.
let previewRep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,pixelsHigh:208,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:960,bitsPerPixel:32)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:previewRep)
NSImage(data:canonical)!.draw(in:NSRect(x:0,y:0,width:240,height:208),from:NSRect(x:0,y:32,width:240,height:208),operation:.sourceOver,fraction:1)
NSGraphicsContext.restoreGraphicsState()
for yy in [0,103,104,207] {var p=[Int](repeating:0,count:4);previewRep.getPixel(&p,atX:120,y:yy);check(Array(p.prefix(3))==rgb(120,yy),"preview crop and uploaded panel agree")}
options.dither=true
check(try! renderedWallpaper(image:image,options:options)==renderedWallpaper(image:image,options:options),"dither rendering is deterministic")
options.saturation = .nan
check((try? renderedWallpaper(image:image,options:options)) == nil,"NaN options rejected")
print("PASS: fit/crop geometry, canonical six-color output, alpha flattening, padding and invalid option rejection")
