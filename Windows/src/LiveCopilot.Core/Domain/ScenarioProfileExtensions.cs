namespace LiveCopilot.Core;


public static class ScenarioProfileExtensions
{
    public static double Cooldown(this ScenarioProfile value) => value == ScenarioProfile.Meeting ? 12 : 7;
    public static string Instructions(this ScenarioProfile value) => value switch
    {
        ScenarioProfile.Interview => "Give a concise, natural spoken interview answer. Use the user's documented experience only when the question asks for or requires personal facts. For general or hypothetical questions, answer directly without forcing a connection to their experience; never invent achievements.",
        ScenarioProfile.Meeting => "Prioritize decisions, exact facts, tradeoffs and next actions. Keep the response brief and practical.",
        ScenarioProfile.Defense => "Explain methods and assumptions precisely. Include sample sizes, limitations and alternative explanations when supported.",
        _ => throw new ArgumentOutOfRangeException(nameof(value))
    };
}
