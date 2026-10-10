import SwiftUI

struct RoadlineStyle {
    var settings = Settings()
    var reduceMotion = false
    var accent: Color {
        switch settings.palette {
        case .roadline: return Color(red: 0.32, green: 0.40, blue: 0.95)
        case .ocean: return Color(red: 0.03, green: 0.62, blue: 0.64)
        case .sunset: return Color(red: 0.91, green: 0.30, blue: 0.30)
        case .bmw: return Color(red: 1, green: 0.39, blue: 0.08)
        }
    }
    var background: Color { settings.palette == .bmw ? Color(red: 0.055, green: 0.05, blue: 0.045) : Color(uiColor: .systemGroupedBackground) }
    var surface: Color { settings.palette == .bmw ? Color(red: 0.115, green: 0.095, blue: 0.075) : Color(uiColor: .secondarySystemGroupedBackground) }
    var ink: Color { settings.palette == .bmw ? Color(red: 1, green: 0.62, blue: 0.23) : Color.primary }
    var secondary: Color { settings.palette == .bmw ? Color(red: 0.88, green: 0.48, blue: 0.25) : Color.secondary }
    var animation: Animation? { settings.motion && !reduceMotion ? .spring(response: 0.42, dampingFraction: 0.8) : nil }
    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaled = size * settings.textScale
        switch settings.typeface {
        case .system: return .system(size: scaled, weight: weight, design: .rounded)
        case .classic: return .system(size: scaled, weight: weight, design: .serif)
        case .technical: return .system(size: scaled, weight: weight, design: .monospaced)
        case .bmw: return .custom(weight == .regular ? "BarlowCondensed-Regular" : "BarlowCondensed-Bold", size: scaled, relativeTo: .title)
        }
    }
}
private struct StyleKey: EnvironmentKey { static let defaultValue = RoadlineStyle() }
extension EnvironmentValues {
    var roadline: RoadlineStyle { get { self[StyleKey.self] } set { self[StyleKey.self] = newValue } }
}
struct RoadlineButtonStyle: ButtonStyle {
    @Environment(\.roadline) private var style
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(.vertical, 17).frame(maxWidth: .infinity)
            .foregroundStyle(primary ? Color.white : style.ink)
            .background(primary ? style.accent : style.surface, in: RoundedRectangle(cornerRadius: configuration.isPressed ? 18 : 28))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(style.animation, value: configuration.isPressed)
    }
}
struct Metric: View {
    @Environment(\.roadline) private var style
    var label: String
    var value: String
    var unit: String
    var icon: String
    var large = false
    var selected = false
    var hint: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        Group {
            if let action = action { Button(action: action) { content }.buttonStyle(.plain) }
            else { content }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value + " " + unit)
        .accessibilityHint(action != nil ? hint ?? "Double tap to switch the reading" : "")
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 6) {
            HStack(alignment: .top, spacing: 5) {
                if !large { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
                Text(label).lineLimit(2).minimumScaleFactor(0.5).layoutPriority(1)
                Spacer(minLength: 0)
                if action != nil { Image(systemName: "arrow.triangle.2.circlepath").font(.caption2) }
            }.font(style.font(large ? 16 : 13, weight: .medium)).foregroundStyle(style.secondary)
            Spacer(minLength: 0)
            Text(value).font(style.font(large ? 96 : 32 * style.settings.supportScale, weight: .bold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.12)
                .contentTransition(.numericText()).frame(maxWidth: .infinity, alignment: .leading)
            Text(unit).font(style.font(large ? 18 : 12)).foregroundStyle(style.secondary).lineLimit(1).minimumScaleFactor(0.5)
            if large, let hint = hint { Text(hint).font(.caption).foregroundStyle(style.secondary).lineLimit(2).minimumScaleFactor(0.7) }
        }
        .padding(large ? 20 : 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(style.ink)
        .background(selected ? style.accent.opacity(style.settings.palette == .bmw ? 0.15 : 0.12) : style.surface,
            in: RoundedRectangle(cornerRadius: large ? 34 : 26))
        .overlay(RoundedRectangle(cornerRadius: large ? 34 : 26).strokeBorder(style.accent.opacity(selected ? 0.5 : 0.08), lineWidth: 1))
        .animation(style.animation, value: label)
        .animation(style.animation, value: value)
    }
}
func reading(_ number: Double?, decimals: Int = 1) -> String {
    guard let number = number, number.isFinite else { return "—" }
    return number.formatted(.number.precision(.fractionLength(decimals)))
}
func durationText(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds)) / 60
    return "\(minutes / 60)h \(minutes % 60)m"
}
func decimalInput(_ value: String) -> Double? {
    guard let number = Double(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), number.isFinite else { return nil }
    return number
}
