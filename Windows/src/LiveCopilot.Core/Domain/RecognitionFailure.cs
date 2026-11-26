namespace LiveCopilot.Core;

public enum RecognitionFailure
{
    [EnumMember(Value = "unknown")] Unknown,
    [EnumMember(Value = "embedding_context")] EmbeddingContext,
    [EnumMember(Value = "inference_failed")] InferenceFailed,
    [EnumMember(Value = "timeout")] Timeout,
    [EnumMember(Value = "runtime_missing")] RuntimeMissing,
    [EnumMember(Value = "runtime_start")] RuntimeStart,
    [EnumMember(Value = "embedding_load")] EmbeddingLoad,
    [EnumMember(Value = "model_load_failed")] ModelLoadFailed,
    [EnumMember(Value = "process_ended")] ProcessEnded,
    [EnumMember(Value = "speech_load_slow")] SpeechLoadSlow,
    [EnumMember(Value = "speech_behind")] SpeechBehind,
}
