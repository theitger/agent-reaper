import AppKit
import SwiftUI

/// Muxy's palette (github.com/theitger/muxy, Theme.swift) minus the ghostty-derived
/// backgrounds: the panel sits on the system material instead.
enum Theme {
    static let textPrimary = dyn(light: 0x1A1A1A, dark: 0xF0F0F0)
    static let textBody = dyn(light: 0x3A3A3A, dark: 0xC8C8C8)
    static let textMuted = dyn(light: 0x707070, dark: 0x9A9A9A)
    static let textDim = dyn(light: 0x909090, dark: 0x6A6A6A)
    static let textFaint = dyn(light: 0xA6A6A6, dark: 0x5A5A5A)
    static let claude = dyn(light: 0xBE5A38, dark: 0xD97757)

    struct Tone {
        let soft: Color
        let strong: Color
    }

    static let greenTone = tone(soft: 0xEEF9E1, strong: 0x3F6F12, base: 0x83CD2D, darkStrong: 0xA9DE6E)
    static let yellow = tone(soft: 0xFEF7DC, strong: 0x8A6100, base: 0xF2B705, darkStrong: 0xF5CF5B)
    static let orange = tone(soft: 0xFFF3E5, strong: 0x9B5609, base: 0xF78C10, darkStrong: 0xFFB45C)
    static let redTone = tone(soft: 0xFEF2F2, strong: 0xB91C1C, base: 0xDC2626, darkStrong: 0xF87171)
    static let neutral = Tone(soft: textPrimary.opacity(0.06), strong: textMuted)

    static let fillHover = textPrimary.opacity(0.04)
    static let fillActive = textPrimary.opacity(0.075)
    static let hairline = textPrimary.opacity(0.09)

    static let ease = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.25)

    private static func tone(soft: Int, strong: Int, base: Int, darkStrong: Int) -> Tone {
        let b = rgb(base)
        let darkSoft = NSColor(srgbRed: b.r, green: b.g, blue: b.b, alpha: 0.16)
        let lightSoft = color(soft)
        let softColor = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkSoft : lightSoft
        })
        return Tone(soft: softColor, strong: dyn(light: strong, dark: darkStrong))
    }

    private static func dyn(light: Int, dark: Int) -> Color {
        let l = color(light), d = color(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        })
    }

    private static func rgb(_ hex: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    private static func color(_ hex: Int) -> NSColor {
        let c = rgb(hex)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// Status pill: soft tint, strong text. Same as Muxy's.
struct Badge: View {
    let text: String
    var tone: Theme.Tone = Theme.neutral

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tone.strong)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(Capsule().fill(tone.soft))
    }
}

/// Muxy's pill: a capsule of faint ink, no border. Darker on hover and
/// press, so it reads as a button without shouting.
struct QuietButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(PillButtonStyle())
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Pill<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false

        var body: some View {
            label
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(hover ? Theme.textPrimary : Theme.textBody)
                .padding(.horizontal, 11)
                .frame(height: 22)
                .background(Capsule().fill(Theme.textPrimary.opacity(pressed ? 0.16 : hover ? 0.11 : 0.07)))
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.15), value: hover)
        }
    }
}

/// A thin used/total bar in ink, like a hairline that fills up.
struct Meter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fillActive)
                Capsule().fill(Theme.textMuted)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
