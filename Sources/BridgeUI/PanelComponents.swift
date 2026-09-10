import SwiftUI

public enum PanelLayout {
    public static let width: CGFloat = 384
    public static let height: CGFloat = 650
    static let inset: CGFloat = 16
}

struct PanelButtonStyle: ButtonStyle {
    var accent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        PanelButtonChrome(label: configuration.label, pressed: configuration.isPressed,
                          accent: accent, destructive: destructive)
    }
}

struct PanelTabButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        PanelButtonChrome(label: configuration.label, pressed: configuration.isPressed,
                          selected: selected)
    }
}

enum PanelButtonFeedback {
    static func opacity(enabled: Bool, pressed: Bool, hovered: Bool) -> Double {
        !enabled ? 0 : pressed ? 0.18 : hovered ? 0.09 : 0
    }
}

/// State belongs to the rendered view, not the short-lived ButtonStyle value.
/// The content shape is applied after padding/frame so empty space is clickable.
private struct PanelButtonChrome<Label: View>: View {
    let label: Label
    let pressed: Bool
    var accent = false
    var destructive = false
    var selected: Bool? = nil
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    private var tint: Color { destructive ? .red : .primary }
    private var background: Color {
        if accent && enabled { return .accentColor }
        if selected == true { return Color(nsColor: .controlBackgroundColor) }
        return .primary.opacity(selected == nil ? 0.045 : 0)
    }
    var body: some View {
        label
            .font(.system(size: 11, weight: selected == true ? .semibold : .medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: selected == nil ? nil : .infinity)
            .frame(height: selected == nil ? 28 : 24)
            .foregroundStyle(enabled ? (accent ? Color.white : destructive ? Color.red : Color.primary) : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 6).fill(background))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill((accent ? Color.white : tint).opacity(
                        PanelButtonFeedback.opacity(enabled: enabled, pressed: pressed, hovered: hovered)))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(selected != nil || accent ? 0 : 0.06))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Unlike the default disclosure label, the whole header is a button.
struct PanelDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PanelButtonStyle())
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content }
        }
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.trailing = trailing()
    }
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            trailing
        }.frame(minHeight: 20)
    }
}

struct SettingToggle: View {
    let title: String
    @Binding var value: Bool
    var hint = ""
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Toggle(isOn: $value) {
            Text(title).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if enabled { value.toggle() } }
        }
        .toggleStyle(.switch).controlSize(.mini)
        .frame(minHeight: 30).contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovered && enabled ? 0.045 : 0)))
        .onHover { hovered = $0 }
        .help(hint)
    }
}

struct TextSetting: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(placeholder, text: $value)
                .font(.system(size: 11)).textFieldStyle(.plain)
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.65)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10)))
                .accessibilityLabel(title)
        }
    }
}

struct InlineNote: View {
    let text: String
    var warning = false
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle").frame(width: 12)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 10)).foregroundStyle(warning ? Color.orange : Color.secondary)
    }
}
