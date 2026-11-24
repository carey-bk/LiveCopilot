import SwiftUI
import AVFoundation

/// What Settings shows as ready or needing setup. Overview, the Services tabs and card headers all
/// read this one result, so they cannot disagree. Every state comes from values the app already
/// tracks; nothing is estimated.
struct SettingsReadiness: Equatable {
    enum Item: CaseIterable { case speech, answers, knowledge, triggers, permissions }
    enum State: Equatable {
        case ready
        /// Needs the user's action; the text says what is missing.
        case needsSetup(String)
        /// Off, empty or not used by the current setup; shown in neutral gray.
        case inactive(String)
    }
    struct Entry: Equatable {
        let item: Item
        let state: State
        /// Listening or answering cannot work until this is set up.
        let blocking: Bool
        var isReady: Bool { state == .ready }
        var needsSetup: Bool { if case .needsSetup = state { return true } else { return false } }
        var reason: String? {
            switch state {
            case .ready: return nil
            case .needsSetup(let text), .inactive(let text): return text
            }
        }
    }

    struct Inputs: Equatable {
        var language: AppLanguage = .english
        var listeningService: ListeningService = .apple
        var hasOpenAIKey = false
        var appleSpeechAvailable = true
        var appleSpeechInstalled = false
        var localSpeechModelInstalled = false
        var reasoningService: ReasoningService = .deepSeek
        var hasAnalysisKey = false
        var documentCount = 0
        var embeddingService: EmbeddingService = .local
        var localEmbeddingInstalled = false
        var localEmbeddingVerification: ServiceVerification = .idle
        var remoteEmbeddingVerification: ServiceVerification = .idle
        var knowledgeNeedsReindex = false
        var automaticSuggestions = true
        var layaState: LayaRuntimeManager.State = .notInstalled
        var mode: OperatingMode = .remote
        var microphoneEnabled = true
        var microphoneAllowed = false
        var screenAudioAllowed = false
    }

    let entries: [Entry]

    init(_ inputs: Inputs) {
        let b = { (en: String, zh: String) in ServiceGuide.text(en, zh, inputs.language) }
        entries = [
            Entry(item: .speech, state: Self.speech(inputs, b), blocking: true),
            Entry(item: .answers, state: Self.answers(inputs, b), blocking: true),
            Entry(item: .permissions, state: Self.permissions(inputs, b), blocking: true),
            Entry(item: .knowledge, state: Self.knowledge(inputs, b), blocking: false),
            Entry(item: .triggers, state: Self.triggers(inputs, b), blocking: false)
        ]
    }

    subscript(item: Item) -> Entry { entries.first { $0.item == item }! }
    /// Items that stop listening or answering from working, in display order.
    var blockers: [Entry] { entries.filter { $0.blocking && $0.needsSetup } }
    /// Everything that needs the user, blocking first.
    var pending: [Entry] { entries.filter(\.needsSetup) }
    var canStart: Bool { blockers.isEmpty }

    static func title(_ item: Item, language: AppLanguage) -> String {
        let b = { (en: String, zh: String) in ServiceGuide.text(en, zh, language) }
        switch item {
        case .speech: return b("Speech recognition", "语音识别")
        case .answers: return b("Answer model", "回答模型")
        case .knowledge: return b("Knowledge base", "知识库")
        case .triggers: return b("Automatic answers", "自动回答")
        case .permissions: return b("Permissions", "权限")
        }
    }

    private static func speech(_ i: Inputs, _ b: (String, String) -> String) -> State {
        switch i.listeningService {
        case .openAI:
            return i.hasOpenAIKey ? .ready : .needsSetup(b("No OpenAI key saved", "尚未保存 OpenAI 密钥"))
        case .apple:
            guard i.appleSpeechAvailable else { return .needsSetup(b("Apple speech needs macOS 26 on a supported Mac", "Apple 语音识别需要 macOS 26 和受支持的 Mac")) }
            return i.appleSpeechInstalled ? .ready : .needsSetup(b("Apple speech model not downloaded", "Apple 语音模型尚未下载"))
        case .zipformer, .paraformer:
            let name = i.listeningService == .zipformer ? "Zipformer" : "Paraformer"
            return i.localSpeechModelInstalled ? .ready : .needsSetup(b("\(name) model not downloaded", "\(name) 模型尚未下载"))
        }
    }

    private static func answers(_ i: Inputs, _ b: (String, String) -> String) -> State {
        let ready = i.reasoningService == .sharedOpenAI ? i.hasOpenAIKey : i.hasAnalysisKey
        guard !ready else { return .ready }
        switch i.reasoningService {
        case .sharedOpenAI, .separateOpenAI: return .needsSetup(b("No OpenAI key saved", "尚未保存 OpenAI 密钥"))
        case .compatible: return .needsSetup(b("No key saved for the custom service", "自定义接口尚未保存密钥"))
        case .deepSeek: return .needsSetup(b("No DeepSeek key saved", "尚未保存 DeepSeek 密钥"))
        case .qwen: return .needsSetup(b("No Qwen key saved", "尚未保存 Qwen 密钥"))
        case .glm: return .needsSetup(b("No GLM key saved", "尚未保存 GLM 密钥"))
        case .kimi: return .needsSetup(b("No Kimi key saved", "尚未保存 Kimi 密钥"))
        }
    }

    /// Remote mode records system audio, and the microphone unless it was switched off;
    /// in-person mode uses only the microphone.
    private static func permissions(_ i: Inputs, _ b: (String, String) -> String) -> State {
        let needsMicrophone = i.mode == .inPerson || i.microphoneEnabled
        let missingMicrophone = needsMicrophone && !i.microphoneAllowed
        let missingSystemAudio = i.mode == .remote && !i.screenAudioAllowed
        switch (missingMicrophone, missingSystemAudio) {
        case (false, false): return .ready
        case (true, true): return .needsSetup(b("Microphone and system audio not allowed", "麦克风和系统音频尚未允许"))
        case (true, false): return .needsSetup(b("Microphone not allowed", "麦克风尚未允许"))
        case (false, true): return .needsSetup(b("System audio not allowed", "系统音频尚未允许"))
        }
    }

    private static func knowledge(_ i: Inputs, _ b: (String, String) -> String) -> State {
        guard i.documentCount > 0 else { return .inactive(b("No documents yet", "尚未导入资料")) }
        if i.embeddingService == .local {
            guard i.localEmbeddingInstalled else { return .needsSetup(b("Index model not downloaded", "索引模型尚未下载")) }
            switch i.localEmbeddingVerification {
            case .ready: break
            case .checking: return .needsSetup(b("Checking the index model…", "正在检测索引模型…"))
            case .failed: return .needsSetup(b("Index model check failed", "索引模型检测未通过"))
            case .idle: return .needsSetup(b("Index model not verified", "索引模型尚未验证"))
            }
        } else {
            guard i.hasOpenAIKey else { return .needsSetup(b("No OpenAI key for indexing", "远程索引尚未保存 OpenAI 密钥")) }
            switch i.remoteEmbeddingVerification {
            case .ready: break
            case .checking: return .needsSetup(b("Checking remote indexing…", "正在检测远程索引…"))
            case .failed: return .needsSetup(b("Remote indexing check failed", "远程索引检测未通过"))
            case .idle: return .needsSetup(b("Remote indexing not verified", "远程索引尚未验证"))
            }
        }
        return i.knowledgeNeedsReindex ? .needsSetup(b("Indexes need rebuilding", "需要重建索引")) : .ready
    }

    /// Local speech engines rely on the Laya model to decide when a question is complete;
    /// GPT-Live-1 makes that decision itself.
    private static func triggers(_ i: Inputs, _ b: (String, String) -> String) -> State {
        guard i.automaticSuggestions else { return .inactive(b("Off · ask manually", "已关闭 · 手动提问")) }
        guard i.listeningService.isLocal else { return .ready }
        switch i.layaState {
        case .installed, .ready: return .ready
        case .unsupported: return .inactive(b("Not available on this Mac", "此 Mac 不支持"))
        case .notInstalled: return .needsSetup(b("Trigger model not downloaded", "触发模型尚未下载"))
        case .installing, .loading: return .needsSetup(b("Preparing the trigger model…", "正在准备触发模型…"))
        case .failed: return .needsSetup(b("Trigger model failed to load", "触发模型加载失败"))
        }
    }
}

extension SettingsReadiness.Entry {
    var tone: LC.Tone {
        switch state {
        case .ready: return .success
        case .needsSetup: return .warning
        case .inactive: return .neutral
        }
    }
    func badge(_ language: AppLanguage) -> (text: String, tone: LC.Tone) {
        let b = { (en: String, zh: String) in ServiceGuide.text(en, zh, language) }
        switch state {
        case .ready: return (b("Ready", "就绪"), .success)
        case .needsSetup: return (b("Set up", "待配置"), .warning)
        case .inactive: return (item == .knowledge ? b("Empty", "空") : b("Off", "未启用"), .neutral)
        }
    }
}

extension SettingsView {
    var readiness: SettingsReadiness {
        let settings = coordinator.settings
        return SettingsReadiness(.init(
            language: settings.language,
            listeningService: settings.listeningService,
            hasOpenAIKey: coordinator.hasAPIKey,
            appleSpeechAvailable: coordinator.appleSpeech.available,
            appleSpeechInstalled: coordinator.appleSpeech.lastKnownInstalled(settings.appleSpeechLanguage),
            localSpeechModelInstalled: settings.listeningService.localModel?.isInstalled(in: localModels.root) == true,
            reasoningService: settings.reasoningService,
            hasAnalysisKey: coordinator.hasAnalysisKey,
            documentCount: coordinator.knowledgeDocuments.count,
            embeddingService: settings.embeddingService,
            localEmbeddingInstalled: localModels.installed.contains(.embedding),
            localEmbeddingVerification: localModels.embeddingLastVerified ? .ready : localModels.embeddingVerification,
            remoteEmbeddingVerification: coordinator.embeddingVerification,
            knowledgeNeedsReindex: coordinator.knowledgeNeedsReindex,
            automaticSuggestions: settings.automaticSuggestions,
            layaState: laya.displayState,
            mode: settings.mode,
            microphoneEnabled: coordinator.micEnabled,
            microphoneAllowed: permissions.microphone == .authorized,
            screenAudioAllowed: permissions.screenAudio))
    }

    /// Where each readiness item is fixed.
    func open(_ item: SettingsReadiness.Item) {
        switch item {
        case .speech: serviceRole = ServiceRole.speechRecognition.rawValue; page = .services
        case .answers: serviceRole = ServiceRole.analysisAndAnswers.rawValue; page = .services
        case .triggers: serviceRole = ServiceRole.answerTriggers.rawValue; page = .services
        case .permissions: page = .general
        case .knowledge:
            if coordinator.knowledgeDocuments.isEmpty || coordinator.knowledgeNeedsReindex { page = .knowledge }
            else { serviceRole = ServiceRole.knowledgeIndexing.rawValue; page = .services }
        }
    }
}
