import SwiftUI

/// Fantasy Market palette and type, ported from the reference page's CSS variables.
enum Theme {
    static let field = Color(hex: 0x0F2B22)   // page background, theme colour
    static let turf = Color(hex: 0x15372C)    // cards, inputs
    static let turf2 = Color(hex: 0x1C4638)   // pressed / banners
    static let chalk = Color(hex: 0xF3F1E8)   // primary text
    static let muted = Color(hex: 0x9DB5A6)   // secondary text
    static let bid = Color(hex: 0x8CC8FF)
    static let ask = Color(hex: 0xFFA08C)
    static let gold = Color(hex: 0xF2C75C)
    static let line = Color(hex: 0xF3F1E8).opacity(0.13)

    /// Condensed display face standing in for Barlow Condensed.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default).width(.condensed)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Cents → "$1,234.56" (negative values render with a leading minus).
    static func money(_ cents: Int) -> String {
        let sign = cents < 0 ? "−" : ""
        let abs = Swift.abs(cents)
        let dollars = grouped.string(from: NSNumber(value: abs / 100)) ?? "\(abs / 100)"
        return "\(sign)$\(dollars).\(String(format: "%02d", abs % 100))"
    }

    static func cents(_ c: Int) -> String { "\(c)¢" }

    static func cents(_ c: Double) -> String {
        c.rounded() == c ? "\(Int(c))¢" : String(format: "%.1f¢", c)
    }

    static func n(_ x: Int) -> String { grouped.string(from: NSNumber(value: x)) ?? "\(x)" }

    static func signed(_ x: Int) -> String { (x > 0 ? "+" : "") + n(x) }
}

// MARK: - Reusable chrome

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(20))
            .foregroundStyle(Theme.field)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.chalk.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(15, weight: .medium))
            .foregroundStyle(Theme.chalk)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Theme.turf2.opacity(configuration.isPressed ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.body(18))
            .foregroundStyle(Theme.chalk)
            .padding(14)
            .background(Theme.turf)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.body(14)).foregroundStyle(Theme.muted)
            content
        }
    }
}
