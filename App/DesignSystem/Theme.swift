import SwiftUI
import SweepCore

extension AppAppearance {
    /// SwiftUI color scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Sweep's visual language: a calm dark-friendly surface with a mint→azure
/// accent used for progress, success and primary actions.
enum Theme {
    static let mint = Color(red: 0.20, green: 0.89, blue: 0.69)
    static let azure = Color(red: 0.24, green: 0.55, blue: 1.00)
    static let violet = Color(red: 0.62, green: 0.44, blue: 1.00)
    static let amber = Color(red: 1.00, green: 0.71, blue: 0.26)
    static let coral = Color(red: 1.00, green: 0.36, blue: 0.36)

    static let accentGradient = LinearGradient(
        colors: [mint, azure],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [mint.opacity(0.9), azure, violet.opacity(0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func pressureColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: mint
        case ..<0.9: amber
        default: coral
        }
    }

    static let cardCornerRadius: CGFloat = 14
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            )
    }
}

extension View {
    func sweepCard(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// Primary call-to-action: gradient capsule with a subtle glow.
struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(Theme.accentGradient, in: Capsule())
            .shadow(color: Theme.azure.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(configuration.isPressed ? 0.9 : 0.6), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
