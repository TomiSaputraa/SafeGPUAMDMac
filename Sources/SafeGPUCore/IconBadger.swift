import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IconBadgerError: LocalizedError {
    case bitmapCreationFailed
    case pngEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .bitmapCreationFailed:
            return "Failed to allocate graphics context for icon rendering."
        case .pngEncodingFailed:
            return "Failed to encode PNG icon representation."
        }
    }
}

public struct IconBadger: Sendable {
    private struct ICNSChunkSpec {
        let osType: String
        let pixels: Int
    }

    // Standard Apple ICNS PNG-backed icon type codes (macOS 10.7 – macOS 15+)
    private static let icnsSpecs: [ICNSChunkSpec] = [
        ICNSChunkSpec(osType: "icp4", pixels: 16),   // 16x16
        ICNSChunkSpec(osType: "ic11", pixels: 32),   // 16x16@2x
        ICNSChunkSpec(osType: "icp5", pixels: 32),   // 32x32
        ICNSChunkSpec(osType: "ic12", pixels: 64),   // 32x32@2x
        ICNSChunkSpec(osType: "icp6", pixels: 64),   // 64x64
        ICNSChunkSpec(osType: "ic07", pixels: 128),  // 128x128
        ICNSChunkSpec(osType: "ic13", pixels: 256),  // 128x128@2x
        ICNSChunkSpec(osType: "ic08", pixels: 256),  // 256x256
        ICNSChunkSpec(osType: "ic14", pixels: 512),  // 256x256@2x
        ICNSChunkSpec(osType: "ic09", pixels: 512),  // 512x512
        ICNSChunkSpec(osType: "ic10", pixels: 1024)  // 512x512@2x
    ]

    public init() {}

    /// Extracts the app icon at `appURL`, overlays a crisp green safe-shield badge, and writes an `.icns` file.
    public func generateBadgedIcon(forAppAt appURL: URL, outputICNSURL: URL) throws {
        let baseIcon = NSWorkspace.shared.icon(forFile: appURL.path)

        try buildICNS(outputICNSURL: outputICNSURL) { pixels in
            try renderPNG(pixels: pixels) { size in
                let fullRect = NSRect(x: 0, y: 0, width: size, height: size)
                baseIcon.draw(
                    in: fullRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )

                // Draw crisp bottom-right green shield badge
                let badgeSize = size * 0.40
                let margin = size * 0.04
                let badgeRect = NSRect(
                    x: size - badgeSize - margin,
                    y: margin,
                    width: badgeSize,
                    height: badgeSize
                )
                Self.drawSafeBadge(in: badgeRect, canvasSize: size)
            }
        }
    }

    /// Generates SafeGPU's own native macOS squircle app icon as an `.icns` file.
    public func generateSafeGPUAppIcon(outputICNSURL: URL) throws {
        try buildICNS(outputICNSURL: outputICNSURL) { pixels in
            try renderPNG(pixels: pixels) { size in
                Self.drawSafeGPUMainIcon(size: size)
            }
        }
    }

    // MARK: - Pure Swift ICNS Assembly

    private func buildICNS(outputICNSURL: URL, renderEntry: (Int) throws -> Data) throws {
        var pngCache: [Int: Data] = [:]
        var body = Data()

        for spec in Self.icnsSpecs {
            let pngData: Data
            if let cached = pngCache[spec.pixels] {
                pngData = cached
            } else {
                pngData = try renderEntry(spec.pixels)
                pngCache[spec.pixels] = pngData
            }

            let chunkLength = UInt32(8 + pngData.count)
            body.append(contentsOf: spec.osType.utf8)
            var bigLen = chunkLength.bigEndian
            withUnsafeBytes(of: &bigLen) { body.append(contentsOf: $0) }
            body.append(pngData)
        }

        let totalLength = UInt32(8 + body.count)
        var icnsData = Data()
        icnsData.reserveCapacity(Int(totalLength))
        icnsData.append(contentsOf: "icns".utf8)
        var bigTotal = totalLength.bigEndian
        withUnsafeBytes(of: &bigTotal) { icnsData.append(contentsOf: $0) }
        icnsData.append(body)

        let parent = outputICNSURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try icnsData.write(to: outputICNSURL, options: .atomic)
    }

    private func renderPNG(pixels: Int, draw: (CGFloat) -> Void) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgContext = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: pixels * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw IconBadgerError.bitmapCreationFailed
        }

        cgContext.interpolationQuality = .high
        cgContext.setAllowsAntialiasing(true)
        cgContext.setShouldAntialias(true)

        let nsContext = NSGraphicsContext(cgContext: cgContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        draw(CGFloat(pixels))
        nsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgContext.makeImage() else {
            throw IconBadgerError.pngEncodingFailed
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw IconBadgerError.pngEncodingFailed
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IconBadgerError.pngEncodingFailed
        }

        return mutableData as Data
    }

    private static func drawSafeBadge(in rect: NSRect, canvasSize: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = max(1.0, canvasSize * 0.025)
        shadow.shadowOffset = NSSize(width: 0, height: -max(0.5, canvasSize * 0.01))

        // Outer white ring with drop shadow
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let outerPath = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill()
        outerPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Inner emerald circle
        let borderWidth = max(1.0, rect.width * 0.09)
        let innerRect = rect.insetBy(dx: borderWidth, dy: borderWidth)
        let innerPath = NSBezierPath(ovalIn: innerRect)

        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.45, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.32, alpha: 1.0)
        )
        gradient?.draw(in: innerPath, angle: -90)

        // Crisp white checkmark inside
        let cx = innerRect.midX
        let cy = innerRect.midY
        let r = innerRect.width * 0.5

        let check = NSBezierPath()
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.lineWidth = max(1.4, innerRect.width * 0.15)
        check.move(to: NSPoint(x: cx - r * 0.42, y: cy - r * 0.02))
        check.line(to: NSPoint(x: cx - r * 0.10, y: cy - r * 0.34))
        check.line(to: NSPoint(x: cx + r * 0.46, y: cy + r * 0.30))
        NSColor.white.setStroke()
        check.stroke()
    }

    private static func drawSafeGPUMainIcon(size: CGFloat) {
        // macOS squircle icon inset (~8.5% margin)
        let inset = size * 0.085
        let cardRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let cornerRadius = cardRect.width * 0.225
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Subtle shadow
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = size * 0.04
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.02)
        shadow.set()
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 1.0).setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Rich dark slate-indigo background gradient
        let bgGradient = NSGradient(
            starting: NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.34, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.18, alpha: 1.0)
        )
        bgGradient?.draw(in: cardPath, angle: -90)

        // Subtle inner rim highlight
        NSColor.white.withAlphaComponent(0.14).setStroke()
        cardPath.lineWidth = max(1.0, size * 0.012)
        cardPath.stroke()

        // Stylized microchip outline centered
        let chipSize = cardRect.width * 0.46
        let chipRect = NSRect(
            x: cardRect.midX - chipSize * 0.5,
            y: cardRect.midY - chipSize * 0.5,
            width: chipSize,
            height: chipSize
        )

        // Chip pins (3 per side)
        let pinLen = cardRect.width * 0.075
        let pinThickness = max(1.2, size * 0.024)
        let pinColor = NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.84, alpha: 0.85)
        pinColor.setFill()
        for i in 0..<3 {
            let frac = CGFloat(i + 1) / 4.0
            let px = chipRect.minX + chipRect.width * frac - pinThickness * 0.5
            let py = chipRect.minY + chipRect.height * frac - pinThickness * 0.5
            NSBezierPath(roundedRect: NSRect(x: px, y: chipRect.maxY, width: pinThickness, height: pinLen), xRadius: pinThickness * 0.4, yRadius: pinThickness * 0.4).fill()
            NSBezierPath(roundedRect: NSRect(x: px, y: chipRect.minY - pinLen, width: pinThickness, height: pinLen), xRadius: pinThickness * 0.4, yRadius: pinThickness * 0.4).fill()
            NSBezierPath(roundedRect: NSRect(x: chipRect.minX - pinLen, y: py, width: pinLen, height: pinThickness), xRadius: pinThickness * 0.4, yRadius: pinThickness * 0.4).fill()
            NSBezierPath(roundedRect: NSRect(x: chipRect.maxX, y: py, width: pinLen, height: pinThickness), xRadius: pinThickness * 0.4, yRadius: pinThickness * 0.4).fill()
        }

        // Chip body
        let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: chipSize * 0.18, yRadius: chipSize * 0.18)
        let chipGrad = NSGradient(
            starting: NSColor(calibratedRed: 0.25, green: 0.34, blue: 0.50, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.35, alpha: 1.0)
        )
        chipGrad?.draw(in: chipPath, angle: -90)
        NSColor(calibratedRed: 0.56, green: 0.74, blue: 0.96, alpha: 0.9).setStroke()
        chipPath.lineWidth = max(1.2, size * 0.022)
        chipPath.stroke()

        // Emerald shield centered on chip
        let shieldW = chipSize * 0.58
        let shieldH = chipSize * 0.66
        let sx = chipRect.midX
        let sy = chipRect.midY
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: sx, y: sy + shieldH * 0.52))
        shield.line(to: NSPoint(x: sx + shieldW * 0.50, y: sy + shieldH * 0.28))
        shield.line(to: NSPoint(x: sx + shieldW * 0.44, y: sy - shieldH * 0.14))
        shield.curve(
            to: NSPoint(x: sx, y: sy - shieldH * 0.52),
            controlPoint1: NSPoint(x: sx + shieldW * 0.36, y: sy - shieldH * 0.36),
            controlPoint2: NSPoint(x: sx + shieldW * 0.14, y: sy - shieldH * 0.46)
        )
        shield.curve(
            to: NSPoint(x: sx - shieldW * 0.44, y: sy - shieldH * 0.14),
            controlPoint1: NSPoint(x: sx - shieldW * 0.14, y: sy - shieldH * 0.46),
            controlPoint2: NSPoint(x: sx - shieldW * 0.36, y: sy - shieldH * 0.36)
        )
        shield.line(to: NSPoint(x: sx - shieldW * 0.50, y: sy + shieldH * 0.28))
        shield.close()

        let shieldGrad = NSGradient(
            starting: NSColor(calibratedRed: 0.22, green: 0.84, blue: 0.50, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.09, green: 0.60, blue: 0.34, alpha: 1.0)
        )
        shieldGrad?.draw(in: shield, angle: -90)

        // White checkmark inside shield
        let check = NSBezierPath()
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.lineWidth = max(1.4, size * 0.042)
        check.move(to: NSPoint(x: sx - shieldW * 0.20, y: sy - shieldH * 0.01))
        check.line(to: NSPoint(x: sx - shieldW * 0.04, y: sy - shieldH * 0.17))
        check.line(to: NSPoint(x: sx + shieldW * 0.24, y: sy + shieldH * 0.16))
        NSColor.white.setStroke()
        check.stroke()
    }
}
