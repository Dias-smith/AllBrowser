import SwiftUI

public enum ABColor {
    public static let background = Color(red: 0.07, green: 0.09, blue: 0.12)
    public static let surface = Color(red: 0.12, green: 0.14, blue: 0.18)
    public static let surfaceElevated = Color(red: 0.16, green: 0.18, blue: 0.24)
    public static let accent = Color(red: 0.20, green: 0.72, blue: 0.68)
    public static let accentSecondary = Color(red: 0.95, green: 0.55, blue: 0.25)
    public static let textPrimary = Color.white.opacity(0.92)
    public static let textSecondary = Color.white.opacity(0.58)
    public static let danger = Color(red: 0.92, green: 0.32, blue: 0.36)
    public static let border = Color.white.opacity(0.08)
}

public enum ABFont {
    public static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    public static func title(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    public static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    public static func mono(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

public struct ABPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ABFont.title(16))
            .foregroundStyle(ABColor.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ABColor.accent)
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
    }
}

public struct ABCardModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ABColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ABColor.border, lineWidth: 1)
                    )
            )
    }
}

public extension View {
    func abCard() -> some View {
        modifier(ABCardModifier())
    }
}

public struct EmptyStateView: View {
    public let title: String
    public let subtitle: String
    public let systemImage: String

    public init(title: String, subtitle: String, systemImage: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(ABColor.accent)
            Text(title)
                .font(ABFont.title(18))
                .foregroundStyle(ABColor.textPrimary)
            Text(subtitle)
                .font(ABFont.body(14))
                .foregroundStyle(ABColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
