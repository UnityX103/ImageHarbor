import AppKit
let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let rect = NSRect(x:s*0.06,y:s*0.06,width:s*0.88,height:s*0.88)
    let bg = NSBezierPath(roundedRect:rect,xRadius:s*0.2,yRadius:s*0.2)
    NSGradient(starting:NSColor(calibratedRed:0.03,green:0.23,blue:0.28,alpha:1),ending:NSColor(calibratedRed:0.1,green:0.65,blue:0.61,alpha:1))!.draw(in:bg,angle:55)
    NSColor.white.withAlphaComponent(0.3).setStroke()
    let back = NSBezierPath(roundedRect:NSRect(x:s*0.22,y:s*0.31,width:s*0.57,height:s*0.43),xRadius:s*0.05,yRadius:s*0.05)
    back.lineWidth=s*0.035; back.stroke()
    NSColor.white.setStroke()
    let front = NSBezierPath(roundedRect:NSRect(x:s*0.17,y:s*0.25,width:s*0.57,height:s*0.43),xRadius:s*0.05,yRadius:s*0.05)
    front.lineWidth=s*0.035; front.stroke()
    let mountain=NSBezierPath(); mountain.move(to:NSPoint(x:s*0.22,y:s*0.31));mountain.line(to:NSPoint(x:s*0.37,y:s*0.48));mountain.line(to:NSPoint(x:s*0.47,y:s*0.38));mountain.line(to:NSPoint(x:s*0.55,y:s*0.46));mountain.line(to:NSPoint(x:s*0.68,y:s*0.31));mountain.close();NSColor.white.withAlphaComponent(0.9).setFill();mountain.fill()
    NSBezierPath(ovalIn:NSRect(x:s*0.55,y:s*0.53,width:s*0.07,height:s*0.07)).fill()
    image.unlockFocus()
    let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:dir).appendingPathComponent("\(size).png"))
}
