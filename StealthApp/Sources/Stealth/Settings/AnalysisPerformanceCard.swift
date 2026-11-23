import SwiftUI

/// A compact, shared metrics row. The same selection and price snapshots power
/// onboarding and Settings; the popover retains source, date and billing scope.
struct AnalysisMetrics: View {
    let settings: AppSettings
    @State private var showDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var reference: AnalysisConfiguration? { AnalysisConfigurations.selection(settings) }
    private var sample: AnalysisPerformanceSample? { AnalysisPerformance.selection(settings).matchingSample }
    private var price: AnalysisPriceDisplay? { AnalysisPricing.display(settings) }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                metricsGrid.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 7) { metricTitle(b("Reference TTFT", "参考首 Token 延迟")); latencyValue }
                        VStack(alignment: .leading, spacing: 7) { metricTitle(b("Generation speed", "参考生成速度")); generationValue }
                    }
                    VStack(alignment: .leading, spacing: 7) { priceTitle; priceValues }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let reference {
                    if reference.kind == .community {
                        Text(b("Reference data from the community", "参考数据来自社区"))
                    } else if let url = URL(string: reference.sourceURL) {
                        Link(reference.source, destination: url)
                        Text("· " + reference.date)
                    }
                } else { Text(b("No reference data", "暂无参考数据")) }
                Spacer(minLength: 0)
                Button(b("Sources & pricing details", "数据与计费说明")) { showDetails = true }
                    .buttonStyle(.plain).foregroundStyle(LC.accent)
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) { details.padding(18).frame(width: 390) }
                    .accessibilityIdentifier("analysis-reference-details")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(b("With thinking on in open-source models, the visible answer may arrive much later than the first token. Network, region, load and request content affect actual speed.", "开源模型开启思考后，回答文字可能明显晚于首 Token；实际速度受网络、地区、负载及请求内容影响。"))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.analysisModel == "kimi-k2.6", settings.analysisThinking == .enabled, let seconds = sample?.firstAnswerSeconds {
                Text(b("Historical AA workload: first visible answer ≈ \(String(format: "%.2f", seconds)) s with thinking on; a benchmark reference, not a guaranteed wait.",
                       "AA 历史测试中，开启思考的首个可见回答约 \(String(format: "%.2f", seconds)) 秒；仅代表该测试口径，不是固定等待时间。"))
                    .font(.system(size: 11)).foregroundStyle(LC.warning).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("analysis-performance")
    }
    private var metricsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            GridRow(alignment: .top) {
                metricTitle(b("Reference TTFT", "参考首 Token 延迟"))
                metricTitle(b("Generation speed", "参考生成速度"))
                priceTitle
            }
            GridRow(alignment: .lastTextBaseline) {
                latencyValue.frame(width: 124, alignment: .leading)
                generationValue.frame(width: 152, alignment: .leading)
                priceValues
            }
        }
    }
    private var priceTitle: some View {
        Text(b("API price / 1M tokens", "API 价格 / 每 100 万 Token"))
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }
    private var latencyValue: some View {
        ratedValue(reference?.ttft, suffix: " s", classify: AnalysisMetricTier.latency,
                   explanation: b("First-token reference: fast ≤1.5 s; moderate >1.5–3.5 s; slow >3.5 s.",
                                  "首 Token 参考：很快 ≤1.5 秒；中等 >1.5–3.5 秒；较慢 >3.5 秒。"), latency: true)
    }
    private var generationValue: some View {
        ratedValue(reference?.speed, suffix: " tok/s", classify: AnalysisMetricTier.generation,
                   explanation: b("Generation reference: fast ≥100 tok/s; moderate ≥50 and <100; slow <50.",
                                  "生成速度参考：很快 ≥100 tok/s；中等 ≥50 且 <100；较慢 <50。"))
    }
    private func ratedValue(_ text: String?, suffix: String, classify: (Double?) -> AnalysisMetricTier?, explanation: String, latency: Bool = false) -> some View {
        let tier = text.flatMap { AnalysisMetricTier.range($0, classify: classify) }
        let estimate = reference?.kind == .estimate
        let slowWait = latency && (text.flatMap(AnalysisMetricTier.bounds)?.lowerBound ?? 0) > 10
        let help = explanation + (estimate ? b(" Estimated range, not measured.", " 估算区间，非实测。") : "") +
            (tier == .uncertain ? b(" The range crosses speed tiers; no single rating is assigned.", " 区间跨越多个速度档位，暂不作单一判断。") : "") +
            (slowWait ? b(" Not suitable for real-time Q&A; consider quality-first use.", " 不适合实时问答，适合质量优先场景。") : "")
        return HStack(alignment: .lastTextBaseline, spacing: 6) {
            metricValue(MetricDisplayFormat.value(text, latency: latency), suffix: suffix)
            AnalysisMetricIcon(tier: tier, language: settings.language, explanation: help)
        }
    }
    @ViewBuilder private var priceValues: some View {
        if let price {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                priceValue(b("Input", "输入"), amount: price.input, currency: price.currency)
                priceValue(b("Output", "输出"), amount: price.output, currency: price.currency)
                }
                AnalysisMetricIcon(tier: .price(price.output, currency: price.currency), language: settings.language,
                                   explanation: price.currency == .cny ?
                    b("Rated by output price per million tokens: inexpensive ≤¥10; moderate >¥10–50; expensive >¥50.",
                      "按每百万输出 Token 单价分档：便宜 ≤¥10；适中 >¥10–50；昂贵 >¥50。") :
                    b("Rated by output price per million tokens: inexpensive ≤$1.5; moderate >$1.5–7.5; expensive >$7.5.",
                      "按每百万输出 Token 单价分档：便宜 ≤$1.5；适中 >$1.5–7.5；昂贵 >$7.5。"))
            }.fixedSize()
        } else { Text(b("Price not verified", "价格待确认")).font(.system(size: 14, weight: .medium)) }
    }
    private func metricTitle(_ title: String) -> some View {
        Text(title + (reference?.kind == .estimate ? b(" · estimate", " · 估算") : ""))
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }
    @ViewBuilder private func metricValue(_ value: String?, suffix: String) -> some View {
        if let value, reference?.kind == .estimate {
            Text(value + suffix).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(.primary)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
        } else if let value {
            StaggeredBlurNumber(value, suffix: suffix, size: 21, leadingAligned: true, compactWidth: true)
        } else {
            Text(b("No reference data", "暂无参考数据")).font(.system(size: 12, weight: .semibold))
        }
    }
    private func priceValue(_ title: String, amount: Double, currency: AnalysisCurrency) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium))
            StaggeredBlurNumber(String(format: "%.2f", amount), prefix: currency.symbol, size: 17, integerPlaces: 2, leadingAligned: true, compactWidth: true)
        }.accessibilityElement(children: .combine)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(b("Reference data", "参考数据")).font(.headline)
            Text((OnboardingAnalysisChoice.displayName(settings) ?? settings.analysisModel) + " · " + settings.analysisThinking.displayName(settings.language))
            if let reference {
                Text(reference.source + " · " + reference.date)
                Text(reference.presentation).foregroundStyle(.secondary)
                Text(reference.basis).foregroundStyle(.secondary)
                Text(reference.limits).foregroundStyle(.secondary)
                if let url = URL(string: reference.sourceURL), !reference.sourceURL.isEmpty {
                    Link(b("Reference basis", "参考依据"), destination: url)
                }
            } else { Text(b("No reliable data for this model, effort and endpoint.", "当前模型、推理档位及端点暂无可靠参考数据。")) }
            Divider()
            Text(b("Price per 1,000,000 tokens", "每 100 万 Token 价格")).font(.headline)
            if let price {
                Text(b("Original quote: ", "原始报价：") + "\(price.quote.currency.rawValue) \(price.quote.input) / \(price.quote.output)" + b(" · input / output", " · 输入 / 输出"))
                Text(price.quote.conditions(settings.language)).foregroundStyle(.secondary)
                Link(b("Provider pricing · snapshot ", "服务商计费 · 价格快照 ") + price.quote.checkedAt, destination: URL(string: price.quote.sourceURL)!)
                if let fx = price.exchangeRate {
                    Text(b("Converted for display: 1 USD = ", "展示金额按汇率换算：1 USD = ") + String(format: "%.6f CNY", fx.cnyPerUSD))
                    Link("ECB · " + fx.date, destination: URL(string: fx.sourceURL)!)
                } else { Text(b("Shown in the source table’s currency.", "当前按参考表的原币种展示。")) }
            } else { Text(b("Price not verified for this model and endpoint. Check your provider's billing page.", "该模型与端点的价格待确认，请查阅服务商计费页面。")) }
            Text(b("Deeper thinking can consume more output tokens. Equal unit prices do not mean equal request cost.", "更深推理可能消耗更多输出 Token；相同单价不代表相同请求成本。"))
                .foregroundStyle(.secondary)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

struct AnalysisPerformanceCard: View {
    let settings: AppSettings
    var onboarding = false
    var body: some View {
        AnalysisMetrics(settings: settings).padding(12).lcWell(radius: LC.Radius.control + 2)
    }
}

/// The slot stays fixed while changed symbols crossfade in place, in step with
/// the existing 250 ms numeric blur. No movement, bounce, or layout animation.
struct AnalysisMetricIcon: View {
    let tier: AnalysisMetricTier?
    let language: AppLanguage
    let explanation: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues:
        ["rocket-launch", "tag", "wallet", "coins"].compactMap { name in
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("MetricIcons/\(name)-fill.svg"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (name, image)
        })
    private var asset: String? {
        switch tier {
        case .fast: return "rocket-launch"
        case .steady: return nil
        case .inexpensive: return "tag"
        case .moderatePrice: return "wallet"
        case .expensive: return "coins"
        default: return nil
        }
    }
    private var title: String {
        let pair: (String, String)
        switch tier {
        case .fast: pair = ("Fast", "很快")
        case .steady: pair = ("Moderate speed", "中等速度")
        case .slow: pair = ("Slow", "较慢")
        case .inexpensive: pair = ("Inexpensive", "便宜")
        case .moderatePrice: pair = ("Moderate price", "价格适中")
        case .expensive: pair = ("Expensive", "昂贵")
        default: pair = ("Uncertain", "档位待定")
        }
        return ServiceGuide.text(pair.0, pair.1, language)
    }
    var body: some View {
        ZStack {
            if tier != nil {
                Group {
                    if tier == .steady {
                        HStack(spacing: 1) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Capsule().frame(width: 5, height: 1.2)
                                Capsule().frame(width: 3, height: 1.2)
                            }
                            Image(systemName: "car.side.fill").font(.system(size: 13, weight: .medium))
                        }.frame(width: 22, height: 19)
                    } else if let asset, let image = Self.images[asset] {
                        Image(nsImage: image).resizable().renderingMode(.template)
                            .scaledToFit().frame(width: 19, height: 19)
                    } else {
                        Image(systemName: tier == .slow ? "tortoise.fill" : "questionmark.circle")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
                .foregroundStyle(Color.secondary).id(tier)
                .transition(reduceMotion ? .opacity : .modifier(active: MetricIconFade(opacity: 0, radius: 2.4),
                                                               identity: MetricIconFade(opacity: 1, radius: 0)))
            }
        }
        .frame(width: 22, height: 22)
        .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 4 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: tier)
        .help(title + "\n" + explanation)
        .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityHint(explanation)
        .accessibilityHidden(tier == nil)
    }
}

private struct MetricIconFade: ViewModifier {
    let opacity: Double
    let radius: CGFloat
    func body(content: Content) -> some View { content.opacity(opacity).blur(radius: radius) }
}

/// Presentation only; ratings continue to use the original reference values.
enum MetricDisplayFormat {
    static func value(_ raw: String?, latency: Bool) -> String? {
        guard let raw else { return nil }
        let parts = raw.components(separatedBy: "–")
        let formatted = parts.compactMap { part -> String? in
            guard let value = Decimal(string: part.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            var input = value
            var output = Decimal()
            NSDecimalRound(&output, &input, latency ? 1 : 0, latency ? .plain : .down)
            return String(format: latency ? "%.1f" : "%.0f", locale: Locale(identifier: "en_US_POSIX"), NSDecimalNumber(decimal: output).doubleValue)
        }
        return formatted.count == parts.count ? formatted.joined(separator: "–") : raw
    }
}
