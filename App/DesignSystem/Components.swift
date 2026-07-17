import SwiftUI
import SweepCore

// MARK: - Gauge ring

struct GaugeRing: View {
    let value: Double
    var lineWidth: CGFloat = 12
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.accentGradient)

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: value)
        }
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = Theme.mint
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sweepCard()
    }
}

// MARK: - Safety badge

struct SafetyBadge: View {
    let tier: SafetyTier

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(tier.label)
                .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }

    private var color: Color {
        switch tier {
        case .safe: Theme.mint
        case .review: Theme.amber
        case .explicitOnly: Theme.coral
        }
    }

    private var symbol: String {
        switch tier {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .explicitOnly: "hand.raised.fill"
        }
    }
}

// MARK: - Byte text

struct ByteText: View {
    let bytes: Int64
    var font: Font = .system(size: 13, weight: .semibold, design: .rounded)

    var body: some View {
        Text(bytes.sweepBytes)
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let text: String
    var color: Color = Theme.mint

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Empty state

struct SweepEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
