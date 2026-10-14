import AppKit

struct WallpaperRenderOptions {
    enum Fit: Int { case contain, cover }
    var fit: Fit = .contain
    var background = 1
    var dither = false
    var saturation: Double = 1
    var x: Double = 0
    var y: Double = 0
}
let wallpaperRGB = [[30,30,30],[160,160,160],[160,160,0],[130,20,20],[0,80,150],[50,100,70]]
func wallpaperImageRect(size: NSSize, options: WallpaperRenderOptions) -> NSRect {
    let scale = options.fit == .contain ? min(240/size.width,208/size.height) : max(240/size.width,208/size.height)
    let w=size.width*scale,h=size.height*scale
    return NSRect(x:(240-w)/2 + max(0,w-240)/2*max(-1,min(1,options.x)),y:32+(208-h)/2+max(0,h-208)/2*max(-1,min(1,options.y)),width:w,height:h)
}
func renderedWallpaper(image: NSImage,options: WallpaperRenderOptions) throws -> Data {
    guard image.size.width>0,image.size.height>0,image.size.width<=8192,image.size.height<=8192,
          options.saturation.isFinite,(0...2).contains(options.saturation),options.x.isFinite,options.y.isFinite,
          wallpaperRGB.indices.contains(options.background),
          let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,pixelsHigh:240,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:960,bitsPerPixel:32),
          let context=NSGraphicsContext(bitmapImageRep:rep) else { throw ProtocolError.invalidSettings }
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    let bg=wallpaperRGB[options.background]
    NSColor(calibratedRed:Double(bg[0])/255,green:Double(bg[1])/255,blue:Double(bg[2])/255,alpha:1).setFill();NSRect(x:0,y:0,width:240,height:240).fill()
    NSRect(x:0,y:32,width:240,height:208).clip()
    image.draw(in:wallpaperImageRect(size:image.size,options:options),from:.zero,operation:.sourceOver,fraction:1)
    NSGraphicsContext.restoreGraphicsState()
    var errors=Array(repeating:[Double](repeating:0,count:3),count:240*240)
    for y in 0..<240 { for x in 0..<240 {
        var pixel=[Int](repeating:0,count:4);rep.getPixel(&pixel,atX:x,y:y)
        let luma=0.2126*Double(pixel[0])+0.7152*Double(pixel[1])+0.0722*Double(pixel[2])
        let rgb=(0..<3).map { c in max(0,min(255,luma+(Double(pixel[c])-luma)*options.saturation+(options.dither && y<208 ? errors[y*240+x][c] : 0))) }
        let nearest=wallpaperRGB.min { a,b in (0..<3).reduce(0.0){$0+pow(Double(a[$1])-rgb[$1],2)} < (0..<3).reduce(0.0){$0+pow(Double(b[$1])-rgb[$1],2)} }!
        var output=nearest+[255];rep.setPixel(&output,atX:x,y:y)
        if options.dither && y<208 {
            for (dx,dy,weight) in [(1,0,7.0/16),(-1,1,3.0/16),(0,1,5.0/16),(1,1,1.0/16)] where (0..<240).contains(x+dx) && (0..<208).contains(y+dy) {
                for c in 0..<3 {errors[(y+dy)*240+x+dx][c]+=(rgb[c]-Double(nearest[c]))*weight}
            }
        }
    } }
    guard let data=rep.representation(using:.png,properties:[:]) else { throw ProtocolError.invalidSettings }
    _=try decodedWallpaperPanel(data);return data
}
func loadWallpaperSource(_ url: URL) throws -> NSImage {
    guard ["png","jpg","jpeg"].contains(url.pathExtension.lowercased()),let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize,size<=20_000_000,
          let image=NSImage(contentsOf:url) else {throw ProtocolError.invalidSettings};return image
}
