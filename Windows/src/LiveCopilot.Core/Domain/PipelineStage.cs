namespace LiveCopilot.Core;

public enum PipelineStage
{
    [EnumMember(Value = "asr_stable")] AsrStable,
    [EnumMember(Value = "question_end")] QuestionEnd,
    [EnumMember(Value = "jev_start")] JevStart,
    [EnumMember(Value = "jev_end")] JevEnd,
    [EnumMember(Value = "analysis_dispatched")] AnalysisDispatched,
    [EnumMember(Value = "embedding_start")] EmbeddingStart,
    [EnumMember(Value = "embedding_complete")] EmbeddingComplete,
    [EnumMember(Value = "rag_complete")] RagComplete,
    [EnumMember(Value = "model_request")] ModelRequest,
    [EnumMember(Value = "first_service_event")] FirstServiceEvent,
    [EnumMember(Value = "reasoning_started")] ReasoningStarted,
    [EnumMember(Value = "first_token")] FirstToken,
    [EnumMember(Value = "answer_complete")] AnswerComplete,
    [EnumMember(Value = "cancelled")] Cancelled,
    [EnumMember(Value = "failed")] Failed,
}
