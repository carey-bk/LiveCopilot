import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var modesAndScenarios: some View {
        VStack(alignment: .leading, spacing: 16) {
            LCSettingsCard(t("Operating mode"), subtitle: b("Which audio is captured and who counts as the other side.", "采集哪路音频，以及谁算作对方。"),
                           systemImage: "waveform", status: lockedStatus) {
                optionGrid(columns: 2) {
                    ForEach(OperatingMode.allCases) { mode in
                        LCOptionCard(title: t(mode.rawValue), detail: modeHint(mode), systemImage: modeSymbol(mode),
                                     selected: coordinator.settings.mode == mode) { coordinator.settings.mode = mode }
                            .accessibilityIdentifier("mode-" + String(describing: mode))
                    }
                }
            }
            LCSettingsCard(t("Scenario"), subtitle: b("Changes how answers are written, not how speech is recognized.", "只改变回答的写法，不影响语音识别。"),
                           systemImage: "theatermasks", status: lockedStatus) {
                optionGrid(columns: 3) {
                    ForEach(ScenarioProfile.allCases) { scenario in
                        LCOptionCard(title: t(scenario.rawValue), detail: scenarioHint(scenario), systemImage: scenarioSymbol(scenario),
                                     selected: coordinator.settings.scenario == scenario) { coordinator.settings.scenario = scenario }
                            .accessibilityIdentifier("scenario-" + String(describing: scenario))
                    }
                }
            }
            automaticAnswersCard
            LCSettingsCard(t("Conversation tools"), subtitle: t("Turning a tool off hides its button and disables its shortcut."),
                           systemImage: "list.bullet.rectangle") {
                LCSettingsRow(t("Recap"), detail: t("Summarize recent topics, decisions and unresolved questions, including action items and owners when mentioned.")) {
                    LCSwitch(title: t("Recap"), isOn: $coordinator.settings.recapEnabled).accessibilityIdentifier("enable-recap")
                }
                Divider()
                LCSettingsRow(t("Follow-up"), detail: t("Suggest **one question you can ask next** to clarify information or explore the topic, phrased naturally to say aloud.")
                    .replacingOccurrences(of: "**", with: "")) {
                    LCSwitch(title: t("Follow-up"), isOn: $coordinator.settings.followUpEnabled).accessibilityIdentifier("enable-follow-up")
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// Jev Mode is switched here only; Services › Answer triggers holds its detailed settings.
    private var automaticAnswersCard: some View {
        let entry = readiness[.triggers]
        return LCSettingsCard("Jev Mode", subtitle: ServiceGuide.text("Automatic question recognition · suggests a reply when a question is complete. You can always ask manually.",
                                                                     "自动识别提问 · 判断提问是否完整，适时生成建议。也可随时手动提问。", coordinator.settings.language),
                              systemImage: "wand.and.sparkles", titleFont: .custom(AppBrandTitle.fontName, size: 19)) {
            HStack(spacing: 8) {
                if entry.needsSetup, let reason = entry.reason {
                    Label(reason, systemImage: "exclamationmark.circle.fill").foregroundStyle(LC.warning)
                } else if !coordinator.settings.automaticSuggestions {
                    Text(b("Off. Answers are generated only when you ask.", "已关闭，只在你提问时生成回答。")).foregroundStyle(.secondary)
                } else if coordinator.settings.listeningService == .openAI {
                    Text(b("GPT-Live-1 decides when a question is complete.", "由 GPT-Live-1 判断提问是否完整。")).foregroundStyle(.secondary)
                } else {
                    Text(b("Sensitivity: ", "触发灵敏度：") + JevSensitivity.nearest(to: coordinator.settings.layaThreshold).title(coordinator.settings.language)
                         + " · " + b("Follow-ups: ", "连续提问：") + t(coordinator.settings.continuousQuestionPolicy.label))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    serviceRole = ServiceRole.answerTriggers.rawValue
                    page = .services
                } label: {
                    HStack(spacing: 4) { Text(b("Adjust", "调整")); Image(systemName: "arrow.right").font(.caption.weight(.semibold)) }
                        .foregroundStyle(LC.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-answer-triggers")
            }
            .font(.callout)
        } accessory: {
            LCSwitch(title: "Jev Mode", isOn: $coordinator.settings.automaticSuggestions)
                .accessibilityIdentifier("automatic-suggestions")
        }
    }

    private var lockedStatus: (text: String, tone: LC.Tone)? {
        locked ? (b("Stop listening to change", "停止监听后可更改"), .neutral) : nil
    }

    private func optionGrid<Content: View>(columns: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) { content() }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(locked)
    }

    /// What each mode does in the code: which input is which speaker and who can trigger answers.
    func modeHint(_ mode: OperatingMode) -> String {
        switch mode {
        case .remote:
            return b("System audio is Them, your microphone is You. Only questions from Them trigger automatic answers.",
                     "系统音频为对方，麦克风为我。只有对方的提问会触发自动回答。")
        case .inPerson:
            return b("One room microphone, speakers are not separated. A question from anyone in the room can trigger an automatic answer.",
                     "只用房间麦克风，不区分说话人。房间里任何人的提问都可能触发自动回答。")
        }
    }
    func modeSymbol(_ mode: OperatingMode) -> String { mode == .remote ? "video" : "person.3" }

    /// Mirrors ScenarioProfile.instructions, which only change how answers are written.
    func scenarioHint(_ scenario: ScenarioProfile) -> String {
        switch scenario {
        case .interview:
            return b("Short, natural answers to say aloud. Your documents are used only when a question asks about your experience.",
                     "回答简短自然、便于说出口；只在问到你的经历时引用资料，不编造经历。")
        case .meeting:
            return b("Answers lead with decisions, exact facts, trade-offs and next actions.",
                     "回答突出决策、准确事实、取舍和下一步行动，简短务实。")
        case .defense:
            return b("Answers explain methods and assumptions precisely, with sample sizes and limitations when supported.",
                     "回答准确说明方法与假设，有依据时补充样本量和局限。")
        }
    }
    func scenarioSymbol(_ scenario: ScenarioProfile) -> String {
        switch scenario {
        case .interview: return "person.text.rectangle"
        case .meeting: return "bubble.left.and.bubble.right"
        case .defense: return "graduationcap"
        }
    }

    var automaticTriggerSettings: some View {
        JevSettingsView(coordinator: coordinator, laya: laya, showModes: { page = .modesAndScenarios })
    }
}
