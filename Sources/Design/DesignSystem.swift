import SwiftUI

enum DS {
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32
    static let radiusSM: CGFloat = 10
    static let radiusMD: CGFloat = 16
    static let radiusLG: CGFloat = 24
}

struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.16), .clear],
                center: .topTrailing,
                startRadius: 30,
                endRadius: 420
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.indigo.opacity(colorScheme == .dark ? 0.18 : 0.10), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 360
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}

extension View {
    func glassSurface(radius: CGFloat = DS.radiusLG) -> some View {
        modifier(GlassSurfaceModifier(radius: radius))
    }

    func contentCard(radius: CGFloat = DS.radiusMD) -> some View {
        background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct StatusPill: View {
    let activity: ThreadActivity
    var compact = false

    private var color: Color {
        switch activity {
        case .active: return .orange
        case .idle: return .green
        case .systemError: return .red
        case .notLoaded, .unknown: return .secondary
        }
    }

    var body: some View {
        Label(activity.title, systemImage: activity == .active ? "sparkles" : activity == .idle ? "checkmark.circle.fill" : "circle")
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 7 : 10)
            .frame(minHeight: compact ? 22 : 28)
            .background(color.opacity(0.10), in: Capsule())
            .accessibilityLabel("状态：\(activity.title)")
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .padding(DS.spacingLG)
    }
}
