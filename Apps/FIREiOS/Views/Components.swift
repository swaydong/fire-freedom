import SwiftUI

enum FIREPalette {
    static let paper = dynamic(
        light: UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.055, green: 0.075, blue: 0.075, alpha: 1)
    )
    static let card = dynamic(
        light: UIColor(white: 1, alpha: 0.82),
        dark: UIColor(red: 0.10, green: 0.13, blue: 0.13, alpha: 0.94)
    )
    static let textInk = Color(uiColor: .label)
    static let accent = dynamic(
        light: UIColor(red: 0.20, green: 0.42, blue: 0.31, alpha: 1),
        dark: UIColor(red: 0.48, green: 0.76, blue: 0.59, alpha: 1)
    )
    static let buttonFill = dynamic(
        light: UIColor(red: 0.08, green: 0.14, blue: 0.15, alpha: 1),
        dark: UIColor(red: 0.78, green: 0.88, blue: 0.82, alpha: 1)
    )
    static let onButton = dynamic(
        light: .white,
        dark: UIColor(red: 0.06, green: 0.10, blue: 0.09, alpha: 1)
    )
    static let separator = Color(uiColor: .separator)

    static let ink = textInk
    static let moss = accent
    static let amber = dynamic(
        light: UIColor(red: 0.82, green: 0.47, blue: 0.16, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.67, blue: 0.31, alpha: 1)
    )
    static let clay = dynamic(
        light: UIColor(red: 0.62, green: 0.28, blue: 0.22, alpha: 1),
        dark: UIColor(red: 0.91, green: 0.50, blue: 0.43, alpha: 1)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
}

extension BridgeConnectionIndicatorState {
    var title: String {
        switch self {
        case .connected: "已连接"
        case .connecting: "连接中"
        case .disconnected: "未连接"
        }
    }

    var color: Color {
        switch self {
        case .connected: FIREPalette.moss
        case .connecting: FIREPalette.amber
        case .disconnected: FIREPalette.clay
        }
    }

    var tabBadgeValue: String {
        switch self {
        case .connected: "✓"
        case .connecting: "…"
        case .disconnected: "!"
        }
    }

    var tabBadgeColor: UIColor {
        switch self {
        case .connected: .systemGreen
        case .connecting: .systemOrange
        case .disconnected: .systemRed
        }
    }
}

struct BridgeStatusPill: View {
    let state: BridgeConnectionIndicatorState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            Text(state.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac 桥接\(state.title)")
    }
}

enum FinancialPrivacy {
    static let storageKey = "dashboard.hidesNumbers"
}

struct FinancialPrivacyFormatter {
    static let hiddenValue = "••••"

    let hidesNumbers: Bool

    func value(_ visibleValue: String) -> String {
        hidesNumbers ? Self.hiddenValue : visibleValue
    }

    func progress(_ visibleProgress: Double) -> Double {
        hidesNumbers ? 0 : visibleProgress
    }
}

struct FinancialPrivacyButton: View {
    @Binding var hidesNumbers: Bool

    var body: some View {
        Button {
            hidesNumbers.toggle()
        } label: {
            Image(systemName: hidesNumbers ? "eye.slash" : "eye")
        }
        .accessibilityLabel(
            hidesNumbers ? "显示所有财务数字" : "隐藏所有财务数字"
        )
        .accessibilityValue(hidesNumbers ? "已隐藏" : "已显示")
        .accessibilityIdentifier("financialPrivacy.toggle")
    }
}

struct FIRECard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FIREPalette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(FIREPalette.separator.opacity(0.55), lineWidth: 1)
            }
    }
}

struct MetricLabel: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(FIREPalette.onButton)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                configuration.isPressed
                    ? FIREPalette.buttonFill.opacity(0.78)
                    : FIREPalette.buttonFill,
                in: RoundedRectangle(cornerRadius: 15)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct StatusToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FIREPalette.moss)
            Text(message)
                .font(.footnote.weight(.medium))
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .padding(.horizontal)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(FIREPalette.moss)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}
