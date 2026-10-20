import Combine
import SwiftUI

@MainActor
final class SettingsPresentation: ObservableObject {
    @Published var isExpanded = false
    let layoutInvalidated = PassthroughSubject<Void, Never>()
}

/// The gear only changes disclosure state. The containing AppKit panel owns
/// the inline settings layout and its single native resize animation.
struct SettingsFooter<Actions: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack {
            actions()
            Spacer()
            Button { isExpanded.toggle() } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
            .help(isExpanded ? "Hide settings" : "Settings")
            .accessibilityLabel(isExpanded ? "Hide settings" : "Show settings")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
    }
}
