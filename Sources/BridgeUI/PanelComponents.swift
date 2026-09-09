import SwiftUI

public enum PanelLayout {
    public static let width: CGFloat = 384
    public static let height: CGFloat = 500
    static let inset: CGFloat = 16
}

struct PanelButtonStyle: ButtonStyle {
    var accent = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(enabled ? (accent ? Color.white : destructive ? Color.red : Color.primary) : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 6).fill(enabled && accent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(accent ? 0 : 0.06)))
            .opacity(configuration.isPressed ? 0.8 : 1)
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
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 11))
            Spacer(minLength: 4)
            Toggle(title, isOn: $value).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }.frame(minHeight: 30).help(hint)
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
