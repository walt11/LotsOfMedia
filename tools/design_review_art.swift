import AppKit
// Synthetic artwork for debug-only component galleries; generated locally, never bundled.
let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory() + "lom-design-art")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let names = ["NORTHERN\nLIGHT", "THE LONG\nWAY HOME", "AFTER\nHOURS", "OPEN\nWATER", "A QUIET\nPLACE", "CITY\nSTORIES", "COAST\nTO COAST", "THE LAST\nJOURNEY"]
let hues: [CGFloat] = [0.44,0.08,0.73,0.54,0.28,0.96,0.5,0.12]
for i in 0..<8 {
 for wide in [false,true] {
  let w = wide ? 960 : 600, h = wide ? 540 : 900
  let image = NSImage(size: NSSize(width:w,height:h))
  image.lockFocus()
  let top = NSColor(calibratedHue:hues[i],saturation:0.55,brightness:0.6,alpha:1)
  let bottom = NSColor(calibratedHue:hues[i],saturation:0.75,brightness:0.12,alpha:1)
  NSGradient(starting:bottom,ending:top)!.draw(in:NSRect(x:0,y:0,width:w,height:h),angle:90)
  NSColor.white.withAlphaComponent(0.35).setFill()
  NSBezierPath(ovalIn:NSRect(x:Double(w)*0.64,y:Double(h)*0.64,width:100,height:100)).fill()
  for layer in 0..<4 {
   NSColor(calibratedHue:hues[i],saturation:0.5,brightness:0.10 + Double(layer)*0.04,alpha:0.85).setFill()
   let path=NSBezierPath();path.move(to:NSPoint(x:0,y:0));path.line(to:NSPoint(x:0,y:Double(h)*0.28+Double(layer)*40))
   let endpoint = NSPoint(x: CGFloat(w), y: CGFloat(h) * 0.34 + CGFloat(layer) * 35)
   let control1 = NSPoint(x: CGFloat(w) * 0.25, y: CGFloat(h) * 0.7)
   let control2 = NSPoint(x: CGFloat(w) * 0.6, y: CGFloat(h) * 0.08)
   path.curve(to: endpoint, controlPoint1: control1, controlPoint2: control2)
   path.line(to:NSPoint(x:w,y:0));path.close();path.fill()
  }
  let style=NSMutableParagraphStyle();style.alignment = .center
  let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:wide ? 48:60,weight:.bold),.foregroundColor:NSColor.white,.paragraphStyle:style,.kern:4]
  let text=NSAttributedString(string:names[i],attributes:attributes)
  text.draw(in:NSRect(x:30,y:Double(h)*0.39,width:Double(w)-60,height:180))
  image.unlockFocus()
  let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
  try! bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("\(wide ? "wide":"cover")\(i).png"))
 }
}
