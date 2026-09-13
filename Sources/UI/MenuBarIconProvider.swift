import AppKit
import SwiftUI

public extension NSImage.Name {
    static let menuBarIcon = NSImage.Name("MenuBarIcon")
}

public enum MenuBarIconProvider {
    /// Creates a pixel-perfect, monochrome vector template NSImage
    /// of the BatteryGuard "battery + clock" motif.
    public static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            
            // AppKit coordinates: y=0 is bottom
            // 1. Draw Battery Outline
            let bodyRect = CGRect(x: 1.5, y: 7.5, width: 14.0, height: 9.5)
            let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)
            ctx.setLineWidth(1.4)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.addPath(bodyPath)
            ctx.strokePath()
            
            // Battery Positive Terminal Nipple
            let termRect = CGRect(x: 15.5, y: 10.0, width: 1.5, height: 4.5)
            let termPath = CGPath(roundedRect: termRect, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(termPath)
            ctx.fillPath()
            
            // Battery Level Fill (~65% state of charge)
            let fillRect = CGRect(x: 3.5, y: 9.5, width: 6.5, height: 5.5)
            let fillPath = CGPath(roundedRect: fillRect, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(fillPath)
            ctx.fillPath()
            
            // 2. Clear circular cutout around clock badge so battery lines don't clash
            let clockCenter = CGPoint(x: 14.5, y: 7.5)
            let cutoutRadius: CGFloat = 6.0
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(
                x: clockCenter.x - cutoutRadius,
                y: clockCenter.y - cutoutRadius,
                width: cutoutRadius * 2,
                height: cutoutRadius * 2
            ))
            
            // 3. Draw Clock Badge
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            
            // Clock outer ring
            let clockRadius: CGFloat = 4.8
            ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: CGRect(
                x: clockCenter.x - clockRadius,
                y: clockCenter.y - clockRadius,
                width: clockRadius * 2,
                height: clockRadius * 2
            ))
            
            // Clock Hands (10:10 position)
            ctx.setLineWidth(1.2)
            // Hour hand pointing to 10 o'clock
            ctx.move(to: clockCenter)
            ctx.addLine(to: CGPoint(x: clockCenter.x - 2.0, y: clockCenter.y + 2.0))
            ctx.strokePath()
            
            // Minute hand pointing to 1 o'clock
            ctx.move(to: clockCenter)
            ctx.addLine(to: CGPoint(x: clockCenter.x + 1.6, y: clockCenter.y + 2.8))
            ctx.strokePath()
            
            // Center pinion dot
            ctx.fillEllipse(in: CGRect(x: clockCenter.x - 0.8, y: clockCenter.y - 0.8, width: 1.6, height: 1.6))
            
            return true
        }
        img.isTemplate = true
        img.setName(.menuBarIcon)
        return img
    }

    /// Ensures the template image is registered with AppKit under the standard name "MenuBarIcon".
    public static func registerIfNeeded() {
        if NSImage(named: .menuBarIcon) == nil {
            _ = makeMenuBarIcon()
        }
    }
}
