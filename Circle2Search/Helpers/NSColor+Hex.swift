import AppKit

extension NSColor {
    /// Create an NSColor from a 6-digit hex string like "#101217".
    convenience init?(hex: String, alpha: CGFloat = 1.0) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.removeFirst() }

        guard hexString.count == 6,
              let value = Int(hexString, radix: 16) else { return nil }

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >>  8) & 0xFF) / 255.0
        let b = CGFloat( value        & 0xFF) / 255.0
        self.init(calibratedRed: r, green: g, blue: b, alpha: alpha)
    }
} 