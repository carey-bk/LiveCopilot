import Foundation

/// Central tuning knobs for the Stealth MVP.
/// Kept in one place so the audio → realtime → suggestion pipeline is easy to reason about.
enum Config {
    /// OpenAI Realtime API websocket endpoint (GA).
    /// Uses the GA realtime model; transcription + text responses share this socket.
    /// GA dropped the `OpenAI-Beta: realtime=v1` header and renamed the model to `gpt-realtime`.
    static let realtimeModel = "gpt-realtime"
    static let realtimeURL = URL(string: "wss://api.openai.com/v1/realtime?model=\(realtimeModel)")!

    /// Sample rate the Realtime API expects for input audio (PCM16, mono, little-endian).
    static let realtimeSampleRate: Double = 24_000

    /// Rolling transcript window (seconds) sent as context when requesting a suggestion.
    /// Smaller = faster + cheaper + more relevant to the current moment.
    static let suggestionContextWindow: TimeInterval = 60

    /// Max transcript lines kept in memory / shown in the overlay.
    static let transcriptLineLimit = 200

    /// Apple voice processing (acoustic echo cancellation + noise suppression) on the
    /// mic. It stops speaker bleed being mislabeled "You", BUT can over-suppress the
    /// user's own voice on some setups → the "You" side captures only silence and VAD
    /// never fires. Turn OFF to test/restore mic sensitivity (echo handling then leans
    /// on the higher `vadThreshold(.you)` instead).
    static let micEchoCancellation = false

    /// VAD silence threshold (ms) before a turn is committed → transcribed.
    /// Lower = snappier transcript, BUT too low fragments continuous speech: natural
    /// speech has frequent sub-second pauses between words, so at 200ms the VAD
    /// commits mid-sentence and words get clipped/dropped at the fragment boundaries
    /// (observed on YouTube/system audio). 700ms waits for a real sentence-ending
    /// pause, keeping lines whole at the cost of a slightly later commit.
    static let vadSilenceMs = 700

    /// VAD speech-detection sensitivity, per speaker (0…1, lower = more sensitive).
    /// The mic ("you") side runs Apple AEC + noise suppression, which lowers the
    /// post-processing level of your own voice — so server VAD at the default 0.5
    /// frequently never fires `speech_stopped`, and your speech is never committed
    /// (the "You side doesn't appear" bug). A lower threshold on the mic side makes
    /// VAD trip on your (quieter, post-AEC) voice. The system ("them") side keeps
    /// the standard threshold to avoid latching onto background noise.
    ///
    /// Values MUST be exactly representable in binary floating point, because
    /// `JSONSerialization` prints e.g. 0.3 as "0.29999999999999999" (17 decimal
    /// places) and the Realtime API rejects >16 dp. 0.25 and 0.5 are safe; 0.3 / 0.4
    /// are NOT. Stick to multiples of 0.25 / 0.5 when tuning these.
    static func vadThreshold(for speaker: Speaker) -> Double {
        switch speaker {
        case .you: return 0.25
        case .them: return 0.5
        }
    }

    /// Keychain identifiers for the OpenAI API key.
    static let keychainService = "com.stealth.app"
    static let keychainAccount = "openai-api-key"

    /// Shared preamble: who the assistant is and who the user is.
    private static let copilotPreamble = """
    You are a silent meeting copilot for a non-native English speaker on a live call \
    with native English (Australian / US) speakers. You are given a rolling transcript \
    of the call, speaker-labelled ("Them:" = the other people, "You:" = the user).
    """

    /// System prompt that shapes the output for a given suggestion mode.
    /// The user is a non-native English speaker on calls with AU/US speakers.
    static func suggestionInstructions(mode: SuggestionMode, tone: ReplyTone) -> String {
        switch mode {
        case .reply:
            return """
            \(copilotPreamble)

            The most recent "Them:" line is what the user needs to respond to.

            Produce a single suggested reply the user can say out loud, in natural, \
            \(tone.descriptor) spoken English. Rules:
            - 1–2 short sentences. Easy to say, no big words.
            - Sound like a confident native speaker, not a textbook.
            - Do NOT explain, do NOT add quotes, do NOT add a preamble. Output only the reply.
            - If the latest line is not a question, suggest a natural acknowledgement or follow-up.
            """
        case .recap:
            return """
            \(copilotPreamble)

            Summarise the conversation so far so the user can catch up quickly.
            - 2–3 short bullet points (use "• " for each), plain spoken English.
            - Capture key decisions, questions raised, and anything the user was asked to do.
            - No preamble, no heading. Output only the bullets.
            """
        case .followUp:
            return """
            \(copilotPreamble)

            Suggest ONE smart, relevant follow-up question the user could ask next to keep \
            the conversation moving or to clarify something important.
            - A single question, natural \(tone.descriptor) spoken English, easy to say.
            - Do NOT explain, do NOT add quotes or a preamble. Output only the question.
            """
        }
    }
}

/// What kind of on-demand assistance the user is asking for.
enum SuggestionMode: String, CaseIterable, Identifiable {
    case reply
    case recap
    case followUp

    var id: String { rawValue }

    /// Short label for the overlay card header.
    var label: String {
        switch self {
        case .reply: return "Reply"
        case .recap: return "Recap"
        case .followUp: return "Follow-up"
        }
    }

    /// SF Symbol for the overlay button.
    var systemImage: String {
        switch self {
        case .reply: return "bubble.left.and.bubble.right"
        case .recap: return "list.bullet.rectangle"
        case .followUp: return "questionmark.bubble"
        }
    }
}

enum ReplyTone: String, CaseIterable, Identifiable {
    case professional
    case casual

    var id: String { rawValue }

    var descriptor: String {
        switch self {
        case .professional: return "polite, professional"
        case .casual: return "friendly, casual"
        }
    }

    var label: String {
        switch self {
        case .professional: return "Professional"
        case .casual: return "Casual"
        }
    }
}
