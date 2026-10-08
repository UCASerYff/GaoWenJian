import AppKit
import Foundation

// Compose the isolated generated lettermark onto a vector background.
// The background is a single sRGB color, so it cannot acquire raster texture.
let arguments = CommandLine.arguments
guard arguments.count == 3, let lettering = NSImage(contentsOfFile:arguments[1]) else {
    fatalError("Usage: ComposeIcon.swift Lettering.png AppIcon.png")
}
let size=1024
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
bitmap.size=NSSize(width:size,height:size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(srgbRed:119.0/255.0,green:119.0/255.0,blue:119.0/255.0,alpha:1).setFill()
// Match the ten existing apps' visible lettermark median (about 602 px high)
// and lettermark-to-background ratio (about 70%), accounting for source padding.
NSBezierPath(roundedRect:NSRect(x:82,y:82,width:860,height:860),xRadius:189,yRadius:189).fill()
NSGraphicsContext.current?.imageInterpolation = .high
// AppKit's y axis points upward; this compensates for the source's low center.
lettering.draw(in:NSRect(x:183,y:196,width:660,height:660),from:.zero,operation:.sourceOver,fraction:1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:arguments[2]),options:.atomic)
