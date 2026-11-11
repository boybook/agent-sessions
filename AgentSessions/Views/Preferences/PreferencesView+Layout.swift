import SwiftUI

/// One settings pane: a grouped Form, the System Settings layout. Each pane's
/// top-level children are `Section`s; Form draws the inset groups, row
/// separators, trailing switches and label/control columns.
struct PreferencesForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// A Form row: label on the leading edge, control on the trailing edge.
struct PreferenceKeyValueRow<Content: View>: View {
    let label: LocalizedStringResource
    let content: Content

    init(label: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            Text(label)
        }
    }
}

struct PreferenceCallout<Content: View>: View {
    let iconName: String
    let tint: Color
    let backgroundColor: Color
    let content: Content

    init(iconName: String = "exclamationmark.triangle.fill",
         tint: Color = .orange,
         backgroundColor: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.iconName = iconName
        self.tint = tint
        self.backgroundColor = backgroundColor ?? tint.opacity(0.12)
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .font(.caption)
            content
        }
        .padding(8)
        .background(backgroundColor)
        .cornerRadius(6)
    }
}

extension PreferencesView {
    // Shared toggle row: a Form switch with the help text as its tooltip
    func toggleRow(_ label: LocalizedStringResource, isOn: Binding<Bool>, help: LocalizedStringResource) -> some View {
        Toggle(isOn: isOn) { Text(label) }
            .help(Text(help))
    }

    func labeledRow<Content: View>(_ label: LocalizedStringResource, @ViewBuilder content: () -> Content) -> some View {
        PreferenceKeyValueRow(label: label, content: content)
    }
}
