import SwiftUI
import UIKit

private struct StableReaderChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Avoid native glass interaction groups beside asynchronously tiled PDF paper.
    var stableReaderChrome: Bool {
        get { self[StableReaderChromeKey.self] }
        set { self[StableReaderChromeKey.self] = newValue }
    }
}

enum Theme {
    // Music-inspired red, with stronger contrast for accessibility settings.
    static let accent = Color(uiColor: UIColor { traits in
        if traits.accessibilityContrast == .high {
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0.44, blue: 0.52, alpha: 1)
                : UIColor(red: 0.72, green: 0.06, blue: 0.17, alpha: 1)
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.29, blue: 0.39, alpha: 1)
            : UIColor(red: 0.89, green: 0.10, blue: 0.22, alpha: 1)
    })
    static let background = Color(uiColor: .systemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let muted = Color(uiColor: .secondaryLabel)
}

/// One glass layer per floating control group. Score content keeps its own paper.
private struct LiquidGlassSurface<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.stableReaderChrome) private var stableReaderChrome
    let shape: S
    let interactive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Theme.surface, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 0.5))
        } else if stableReaderChrome {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

struct GlassActionStyle: PrimitiveButtonStyle {
    @Environment(\.stableReaderChrome) private var stableReaderChrome
    var prominent = false

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *), !stableReaderChrome {
            if prominent {
                action(configuration).buttonStyle(.glassProminent)
            } else {
                action(configuration).buttonStyle(.glass)
            }
        } else if prominent {
            action(configuration).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            action(configuration).buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    private func action(_ configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
    }
}

/// Nearby floating surfaces share the system's glass rendering container.
struct GlassControlGroup<Content: View>: View {
    @Environment(\.stableReaderChrome) private var stableReaderChrome
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *), !stableReaderChrome {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(LiquidGlassSurface(shape: shape, interactive: interactive))
    }

    func liquidGlass(cornerRadius: CGFloat = 24) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func percuscorePanel() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.groupedBackground)
            .tint(Theme.accent)
    }

    func percuscoreSheet() -> some View {
        tint(Theme.accent)
            .presentationCornerRadius(28)
            .presentationDragIndicator(.visible)
    }
}
