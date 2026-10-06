import AppKit
let root = CommandLine.arguments[1]
let iconset = CommandLine.arguments[2]
let points: [CGPoint] = [CGPoint(x:330,y:220),CGPoint(x:330,y:732),CGPoint(x:452,y:622),CGPoint(x:552,y:834),CGPoint(x:665,y:780),CGPoint(x:562,y:572),CGPoint(x:735,y:572)]
func render(_ size:Int, menu:Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let ctx = NSGraphicsContext(bitmapImageRep:rep)!.cgContext
    ctx.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    ctx.translateBy(x:0,y:1024); ctx.scaleBy(x:1,y:-1)
    let tile = CGPath(roundedRect:CGRect(x:54,y:54,width:916,height:916),cornerWidth:206,cornerHeight:206,transform:nil)
    let cursor = CGMutablePath()
    cursor.move(to:points[0]); for p in points.dropFirst() {cursor.addLine(to:p)};cursor.closeSubpath()
    let space = CGColorSpaceCreateDeviceRGB()
    if !menu {
        ctx.saveGState()
        ctx.setShadow(offset:CGSize(width:0,height:-10),blur:18,color:NSColor.black.withAlphaComponent(0.14).cgColor)
        ctx.setFillColor(NSColor.white.cgColor);ctx.addPath(tile);ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState();ctx.addPath(tile);ctx.clip()
        let colors = [NSColor.white.cgColor,NSColor(calibratedWhite:0.98,alpha:1).cgColor,NSColor(calibratedWhite:0.87,alpha:1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace:space,colors:colors,locations:[0,0.45,1])!
        ctx.drawLinearGradient(gradient,start:CGPoint(x:160,y:80),end:CGPoint(x:880,y:970),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        // Blueprint grid, clipped to the existing rounded background.
        for step in stride(from: 64, through: 960, by: 32) {
            let major = step % 128 == 0
            ctx.setStrokeColor(NSColor(calibratedRed:0.35,green:0.52,blue:0.63,alpha:major ? 0.32 : 0.15).cgColor)
            ctx.setLineWidth(major ? 2 : 1)
            ctx.move(to:CGPoint(x:step,y:54));ctx.addLine(to:CGPoint(x:step,y:970))
            ctx.move(to:CGPoint(x:54,y:step));ctx.addLine(to:CGPoint(x:970,y:step));ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.addPath(tile);ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor);ctx.setLineWidth(3);ctx.strokePath()
        ctx.saveGState()
        ctx.setShadow(offset:CGSize(width:8,height:-12),blur:16,color:NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.setFillColor(NSColor.black.cgColor);ctx.addPath(cursor);ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState();ctx.addPath(cursor);ctx.clip()
        let ink = CGGradient(colorsSpace:space,colors:[NSColor(calibratedWhite:0.20,alpha:1).cgColor,NSColor(calibratedWhite:0.02,alpha:1).cgColor] as CFArray,locations:[0,1])!
        ctx.drawLinearGradient(ink,start:CGPoint(x:330,y:220),end:CGPoint(x:665,y:830),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        ctx.restoreGState()
    } else {
        ctx.setFillColor(NSColor.black.cgColor);ctx.addPath(cursor);ctx.fillPath()
    }
    return rep.representation(using:.png,properties:[:])!
}
for n in [16,32,128,256,512] {
    try render(n).write(to:URL(fileURLWithPath:"\(iconset)/icon_\(n)x\(n).png"))
    try render(n*2).write(to:URL(fileURLWithPath:"\(iconset)/icon_\(n)x\(n)@2x.png"))
}
try render(1024).write(to:URL(fileURLWithPath:"\(root)/AppIcon.png"))
try render(36,menu:true).write(to:URL(fileURLWithPath:"\(root)/MenuIcon.png"))
