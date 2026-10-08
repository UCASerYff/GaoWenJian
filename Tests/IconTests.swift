import AppKit
import Foundation

let url=URL(fileURLWithPath:CommandLine.arguments[1])
guard let image=NSBitmapImageRep(data:try Data(contentsOf:url)),image.pixelsWide==1024,image.pixelsHigh==1024,
      let expected=image.colorAt(x:100,y:500)?.usingColorSpace(.deviceRGB) else {fatalError("Invalid icon")}
for y in 300..<700 {
    for x in Array(90..<240)+Array(810..<930) {
        guard let c=image.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),
              c.redComponent==expected.redComponent,c.greenComponent==expected.greenComponent,
              c.blueComponent==expected.blueComponent,c.alphaComponent==1 else {fatalError("Icon background contains a non-uniform pixel")}
    }
}
guard expected.redComponent==expected.greenComponent,expected.greenComponent==expected.blueComponent else {fatalError("Icon background is not neutral gray")}
print("PASS: 108,000 background pixels have the same opaque neutral gray, without texture.")

// Measure visible strokes, not the transparent lettering asset's full canvas.
// The ten sibling apps' median visible lettering measures about 298 × 602 px.
var left=1024, top=1024, right=0, bottom=0
for y in 100..<920 {
    for x in 300..<720 {
        if let c=image.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),
           c.alphaComponent>0.95, min(c.redComponent,c.greenComponent,c.blueComponent)>0.88 {
            left=min(left,x); right=max(right,x); top=min(top,y); bottom=max(bottom,y)
        }
    }
}
let width=right-left+1, height=bottom-top+1
guard (290...310).contains(width), (596...610).contains(height),
      abs(Double(left+right)/2-512)<4, abs(Double(top+bottom)/2-512)<4 else {
    fatalError("Visible lettermark no longer matches the ten sibling apps' size or center")
}
print("PASS: visible lettermark \(width) × \(height) px matches the sibling apps and is centered.")
