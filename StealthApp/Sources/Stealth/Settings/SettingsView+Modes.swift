import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var modesAndScenarios: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(t("Operating mode"), selection: $coordinator.settings.mode) {
                        ForEach(OperatingMode.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    Text(b("Remote Meeting separates system audio (Them) from your microphone (You); In-Person uses one room microphone, without speaker diarization.", "远程会议：系统音频标为对方、麦克风标为我；现场/答辩：仅用房间麦克风，不区分具体说话人。")).font(.caption).foregroundStyle(.secondary)
                    Picker(t("Scenario"), selection: $coordinator.settings.scenario) {
                        ForEach(ScenarioProfile.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    Text(b("Interview: personal experience and talking points. Meeting: decisions and next actions. Defense: methods, evidence and limitations. These change answer instructions, not ASR accuracy.", "面试：个人经历与表达要点；会议：决策与后续行动；答辩：方法、证据与局限。场景改变回答提示词，不改变语音识别准确率。")).font(.caption).foregroundStyle(.secondary)
                    if locked { Text(t("Stop listening to change mode or scenario.")).font(.caption).foregroundStyle(.secondary) }
                }.padding(10)
            } label: { Label(t("Conversation"), systemImage: "waveform") }
            JevModeCard(isOn: $coordinator.settings.automaticSuggestions, language: coordinator.settings.language,
                        identifier: "automatic-suggestions", showTriggerSettings: {
                page = .services
                serviceRole = ServiceRole.answerTriggers.rawValue
            })
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(t("Recap"), isOn: $coordinator.settings.recapEnabled)
                        .accessibilityIdentifier("enable-recap")
                    Text(t("Summarize recent topics, decisions and unresolved questions, including action items and owners when mentioned."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle(t("Follow-up"), isOn: $coordinator.settings.followUpEnabled)
                        .accessibilityIdentifier("enable-follow-up")
                    Text(.init(t("Suggest **one question you can ask next** to clarify information or explore the topic, phrased naturally to say aloud.")))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(t("Turning a tool off hides its button and disables its shortcut."))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Conversation tools"), systemImage: "list.bullet.rectangle") }
        }.padding(.bottom, 4)
    }
    var automaticTriggerSettings: some View {
        JevSettingsView(coordinator: coordinator, laya: laya)
    }
}
