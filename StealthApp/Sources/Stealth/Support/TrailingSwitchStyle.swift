import SwiftUI

/// Keep labels readable while compact native switches line up at the row's trailing edge.
struct TrailingSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .frame(maxWidth: .infinity)
    }
}
