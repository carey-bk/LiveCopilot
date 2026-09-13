import Foundation
@main struct TestMain {
    static func main() async {
        do {
            let checks = try await CoreChecks.run()
            checks.forEach { print("PASS \($0)") }
            print("\(checks.count) deterministic checks passed. No real API calls.")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
