import SwiftUI

struct AnalysisPerformanceCard: View {
    let settings: AppSettings
    private var selection: AnalysisPerformanceSelection { AnalysisPerformance.selection(settings) }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, settings.language) }
    private func effortName(_ effort: String) -> String {
        switch effort {
        case "none": return b("thinking off", "关闭思考")
        case "unspecified": return b("effort not reported", "未区分推理档位")
        case "modelDefault": return b("model default", "模型默认")
        case "enabled": return b("thinking on", "开启思考")
        default: return effort
        }
    }
    private func seconds(_ value: Double) -> String { String(format: "≈ %.2f s", value) }
    private func speed(_ value: Double) -> String { String(format: "≈ %.0f tok/s", value) }
    var body: some View {
        let result = selection
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(b("Performance reference", "性能参考"), systemImage: "speedometer").font(.subheadline.weight(.semibold))
                Spacer()
                Text(b("Reasoning: ", "推理深度：") + effortName(result.effort)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                metric(b("Expected first token", "期望首 Token 延迟"),
                       value: result.matchingSample.map { seconds($0.firstTokenSeconds) })
                metric(b("Expected generation speed", "期望生成速度"),
                       value: result.matchingSample.map { speed($0.tokensPerSecond) })
            }
            if let sample = result.sample {
                HStack(spacing: 4) {
                    Text(b("Source:", "数据来源：")).foregroundStyle(.secondary)
                    Link(sample.source == "OpenRouter" ? "OpenRouter → " + sample.route : sample.source, destination: URL(string: sample.url)!)
                }.font(.caption)
                    .help(b("Public snapshot: ", "公开基准快照：") + sample.capturedAt + " · " + sample.effort + " · " + sample.route)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("analysis-performance")
        .help(b("Public reference, not a local measurement. TTFT may start with a reasoning token. Network, prompt length and provider route affect results.", "公开基准参考，并非本机实测。首 Token 可能是思考 Token；网络、输入长度和服务通道会影响结果。"))
    }
    private func metric(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? b("No published data for this effort", "未公开该档数据"))
                .font(value == nil ? .callout : .title3.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
