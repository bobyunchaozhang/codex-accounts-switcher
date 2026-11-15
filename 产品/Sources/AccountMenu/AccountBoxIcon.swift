import AppKit

// Material Symbols account-box, Google, Apache-2.0.
// Exact quadratic outline from https://api.iconify.design/material-symbols/account-box.svg.
enum AccountBoxIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.saveGState()
            defer { c.restoreGState() }
            c.translateBy(x: 0, y: rect.height)
            c.scaleBy(x: rect.width / 24, y: -rect.height / 24)
            let p = CGMutablePath()
            func m(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x:x,y:y)) }
            func l(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x:x,y:y)) }
            func q(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) { p.addQuadCurve(to: CGPoint(x:x,y:y), control: CGPoint(x:cx,y:cy)) }
            m(14.475,11.975); q(15.5,10.95,15.5,9.5); q(15.5,8.05,14.475,7.025)
            q(13.45,6,12,6); q(10.55,6,9.525,7.025); q(8.5,8.05,8.5,9.5)
            q(8.5,10.95,9.525,11.975); q(10.55,13,12,13); q(13.45,13,14.475,11.975); p.closeSubpath()
            m(5,21); q(4.175,21,3.588,20.413); q(3,19.826,3,19); l(3,5)
            q(3,4.175,3.588,3.588); q(4.176,3,5,3); l(19,3)
            q(19.825,3,20.413,3.588); q(21,4.176,21,5); l(21,19)
            q(21,19.825,20.413,20.413); q(19.826,21,19,21); p.closeSubpath()
            m(5,19); l(19,19); l(19,17.85); q(17.65,16.525,15.863,15.763)
            q(14.076,15,12,15); q(9.924,15,8.137,15.763); q(6.35,16.526,5,17.85); p.closeSubpath()
            c.addPath(p); c.setFillColor(NSColor.black.cgColor); c.drawPath(using: .eoFill)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex 账号"
        return image
    }
}
