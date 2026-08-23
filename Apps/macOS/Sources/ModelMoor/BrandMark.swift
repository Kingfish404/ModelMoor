import AppKit
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct MooringMenuIcon: View {
    let phase: TunnelPhase

    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: 18, height: 18)
            .accessibilityLabel(accessibilityText)
    }

    private static let templateImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setStroke()

            let ribbon = NSBezierPath()
            ribbon.lineWidth = 2.3
            ribbon.lineCapStyle = .round
            ribbon.lineJoinStyle = .round
            ribbon.move(to: NSPoint(x: 3.2, y: 13.2))
            ribbon.line(to: NSPoint(x: 3.2, y: 5.8))
            ribbon.curve(
                to: NSPoint(x: 5.7, y: 4.8),
                controlPoint1: NSPoint(x: 3.2, y: 4.35),
                controlPoint2: NSPoint(x: 4.55, y: 3.85)
            )
            ribbon.curve(
                to: NSPoint(x: 9, y: 9.7),
                controlPoint1: NSPoint(x: 6.85, y: 5.8),
                controlPoint2: NSPoint(x: 8.1, y: 8.75)
            )
            ribbon.curve(
                to: NSPoint(x: 12.3, y: 4.8),
                controlPoint1: NSPoint(x: 9.9, y: 8.75),
                controlPoint2: NSPoint(x: 11.15, y: 5.8)
            )
            ribbon.curve(
                to: NSPoint(x: 14.8, y: 5.8),
                controlPoint1: NSPoint(x: 13.45, y: 3.85),
                controlPoint2: NSPoint(x: 14.8, y: 4.35)
            )
            ribbon.line(to: NSPoint(x: 14.8, y: 13.2))
            ribbon.stroke()

            let terminals = NSBezierPath()
            terminals.lineWidth = 1.45
            terminals.appendOval(in: NSRect(x: 1.4, y: 12.8, width: 3.6, height: 3.6))
            terminals.appendOval(in: NSRect(x: 13, y: 12.8, width: 3.6, height: 3.6))
            terminals.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private var accessibilityText: String {
        switch phase {
        case .connected: "ModelMoor connected"
        case .connecting: "ModelMoor connecting"
        case .waitingForNetwork: "ModelMoor waiting for network"
        case .disconnecting: "ModelMoor disconnecting"
        case .waitingToRetry: "ModelMoor waiting to retry"
        case .failed: "ModelMoor connection failed"
        case .stopped: "ModelMoor stopped"
        }
    }
}
