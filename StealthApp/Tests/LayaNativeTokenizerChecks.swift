import Foundation

@main
struct LayaNativeTokenizerChecks {
    static func main() throws {
        let args = CommandLine.arguments
        let tokenizer = try Tokenizer(args[1], args[2])
        for text in ["", "<mask>", " \t\n"] {
            do { _ = try tokenizer.input(text, [:]); fatalError("accepted empty input") }
            catch TokenError.invalidInput {}
        }
        for text in [String(repeating: "abracadabra", count: 5957), "e\u{301}与é",
                     "👩🏾‍💻🏳️‍🌈", "\u{0}\u{01}\u{1f}", "你好<mask>world"] {
            let ids = try tokenizer.input(text, [:])
            precondition((1...1024).contains(ids.count))
        }
        var matched = 0
        for path in args.dropFirst(3) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            for row in rows {
                let context = row["context"] as? [String: Any] ?? [:]
                if row["context"] is String { precondition(row["context"] as? String == "") }
                let ids = try tokenizer.input(row["text"] as! String, context)
                func bytes(_ values: [Int]) -> Data {
                    values.map { Int32($0).littleEndian }.withUnsafeBytes { Data($0) }
                }
                precondition(bytes(ids) == bytes(row["ids"] as! [Int]))
                precondition(bytes(tokenizer.markers) == bytes(row["markers"] as! [Int]))
                precondition(row["qtype"] as? Int == SwiftEngineConstants.questionType)
                matched += 1
            }
        }
        precondition(matched == 736)
        print("736/736 input_ids, markers and qtype matched; 8 boundary cases passed")
    }
}
