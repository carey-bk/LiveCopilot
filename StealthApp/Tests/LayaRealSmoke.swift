import Foundation

@main struct LayaRealSmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = URL(fileURLWithPath: CommandLine.arguments[2])
        let runtime = LayaRuntimeManager(root: root, resources: resources)
        let start = Date()
        try await runtime.prepareAndWait()
        print("warmup_seconds=\(Date().timeIntervalSince(start))")
        let samples = [
            ("en-question", "Could you explain how you would improve this system's performance?", "We are discussing software architecture."),
            ("en-statement", "The meeting starts tomorrow at nine.", "We are arranging the meeting."),
            ("zh-question", "请介绍一下你在这个项目中具体负责哪些工作？", "对方正在面试我。"),
            ("zh-statement", "今天我们先讨论项目进度，明天再看预算。", "我们在开会。"),
            ("long-input", String(repeating: "Earlier discussion. 之前的讨论。", count: 900) + "Can you explain your approach?", "")
        ]
        for (label, text, context) in samples {
            let begin = Date()
            let score = try await runtime.predict(text: text, context: context)
            print("\(label) score=\(score) latency_ms=\(Int(Date().timeIntervalSince(begin)*1000))")
        }
        await runtime.shutdown()
        print("offline_smoke_passed")
    }
}
