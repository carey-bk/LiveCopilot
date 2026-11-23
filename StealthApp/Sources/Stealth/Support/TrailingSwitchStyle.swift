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

struct JevModeCard<Details: View>: View {
    @Binding var isOn: Bool
    let language: AppLanguage
    let identifier: String
    let showTriggerSettings: (() -> Void)?

    let details: Details

    init(isOn: Binding<Bool>, language: AppLanguage, identifier: String,
         showTriggerSettings: (() -> Void)? = nil, @ViewBuilder details: () -> Details = { EmptyView() }) {
        _isOn = isOn
        self.language = language
        self.identifier = identifier
        self.showTriggerSettings = showTriggerSettings
        self.details = details()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Jev Mode").font(.custom(AppBrandTitle.fontName, size: 21))
                    Text(ServiceGuide.text("Automatic question recognition", "自动识别提问", language))
                        .font(.caption.weight(.medium))
                }
                Spacer(minLength: 0)
                Toggle("Jev Mode", isOn: $isOn)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityIdentifier(identifier)
            }
            Text(ServiceGuide.text("Suggest a reply when a question is complete. You can always ask manually.", "判断提问是否完整，适时生成建议。也可随时手动提问。", language))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            details
            if let showTriggerSettings {
                Button(ServiceGuide.text("View real-time answer triggers", "查看实时回答触发", language), action: showTriggerSettings)
                    .buttonStyle(.link)
            }
        }
        .padding(12)
        .background(isOn ? LC.accent.opacity(0.07) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}
