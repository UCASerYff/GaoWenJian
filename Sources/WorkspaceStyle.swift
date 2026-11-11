import AppKit
import SwiftUI

/// A quiet paper palette that follows the system appearance.
enum WorkspaceStyle {
    static let accent = adaptive(light: 0x326B58, dark: 0x8EC7AA)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x17261F)
    static let canvas = adaptive(light: 0xF7F6F2, dark: 0x202320)
    static let sidebar = adaptive(light: 0xEEEFE9, dark: 0x252A26)
    static let surface = adaptive(light: 0xFFFEFB, dark: 0x2B302C)
    static let line = adaptive(light: 0xDDDFD7, dark: 0x414940)
    static let muted = adaptive(light: 0x657064, dark: 0xB5BEB2)
    static let latex = adaptive(light: 0x326B58, dark: 0x8EC7AA)
    static let markdown = adaptive(light: 0x5C638D, dark: 0xB6BCE6)
    static let pdf = adaptive(light: 0xA36146, dark: 0xE4AB8F)

    static func color(for kind: FileKind) -> Color {
        switch kind {
        case .latex: return latex
        case .markdown: return markdown
        case .pdf: return pdf
        default: return muted
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct WorkspaceSurface: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(WorkspaceStyle.line.opacity(0.75), lineWidth: 1))
    }
}

extension View {
    func workspaceSurface(radius: CGFloat = 16) -> some View { modifier(WorkspaceSurface(radius: radius)) }
}
