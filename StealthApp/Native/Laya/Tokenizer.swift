import Foundation

enum TokenError: Error { case invalidInput }

struct Piece {
  let id: Int
  let start: Int  // Original Unicode scalar index, matching Python slicing.
}

final class Tokenizer {
  private var vocab = [Data: Int]()
  private var merges = [UInt64: (Int, Int)]()
  private var added = [String: Int]()
  private var addedPattern: NSRegularExpression!
  private let question: [String: Any]
  private var prefix = [Int]()
  private(set) var markers = [Int]()
  private func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) << 32 | UInt64(b) }

  init(_ path: String, _ questionPath: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let raw = String(decoding: data, as: UTF8.self)
    let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    struct FileModel: Decodable {
      struct Model: Decodable { let merges: [[String]] }
      let model: Model
    }
    let model = try JSONDecoder().decode(FileModel.self, from: data).model
    question =
      try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: questionPath)))
      as! [String: Any]
    // Swift String dictionaries equate canonically equivalent text. Parse vocab keys
    // individually to preserve distinct UTF-8 spellings in the source checkpoint.
    let start = raw.range(of: "\"vocab\"")!.upperBound
    let end = raw.range(
      of: #""merges"\s*:\s*\["#, options: .regularExpression, range: start..<raw.endIndex)!
      .lowerBound
    let table = String(raw[start..<end]) as NSString
    let kv = try NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"\s*:\s*(\d+)"#)
    kv.enumerateMatches(in: table as String, range: NSRange(location: 0, length: table.length)) {
      m, _, _ in
      guard let m else { return }
      var s = table.substring(with: m.range(at: 1))
      if s.contains("\\") {
        s = try! JSONDecoder().decode(String.self, from: Data(("\"" + s + "\"").utf8))
      }
      self.vocab[Data(s.utf8)] = Int(table.substring(with: m.range(at: 2)))!
    }
    for (rank, p) in model.merges.enumerated() {
      guard let a = vocab[Data(p[0].utf8)], let b = vocab[Data(p[1].utf8)] else {
        throw TokenError.invalidInput
      }
      merges[key(a, b)] = (rank, vocab[Data((p[0] + p[1]).utf8)]!)
    }
    for entry in root["added_tokens"] as! [[String: Any]] {
      added[entry["content"] as! String] = entry["id"] as? Int
    }
    let patterns = added.keys.sorted { $0.utf8.count > $1.utf8.count }.map(
      NSRegularExpression.escapedPattern)
    addedPattern = try NSRegularExpression(pattern: patterns.joined(separator: "|"))
    let criteria = question["criteria"] as! [String: String]
    let options = ["false", "true"].map {
      [4] + encode(" " + $0 + ": " + criteria[$0]!).prefix(48).map(\.id)
    }
    let budget = 256 - options.map(\.count).reduce(0, +)
    prefix =
      [2]
      + encode("noul question: " + (question["instructions"] as! String)).prefix(budget).map(\.id)
      + [1]
    for o in options {
      markers.append(prefix.count)
      prefix += o
    }
    prefix.append(1)
  }
  private func segment(_ text: String, _ base: Int) -> [Piece] {
    var result = [Piece]()
    var word = [Piece]()
    func flush() {
      defer { word.removeAll(keepingCapacity: true) }
      guard word.count > 1 else {
        result += word
        return
      }
      // Stable linked indices and a priority queue preserve leftmost ties.
      // Invalidated neighbours are discarded lazily, bounding a long word
      // to O(n log n) work without moving its suffix on each merge.
      struct Candidate: Comparable {
        let rank: Int, left: Int, right: Int, token: Int
        static func < (a: Self, b: Self) -> Bool {
          (a.rank, a.left) < (b.rank, b.left)
        }
      }
      var next = Array(1...word.count)
      var previous = Array(-1..<word.count - 1)
      var heap = [Candidate]()
      func enqueue(_ left: Int) {
        guard left >= 0, left < word.count else { return }
        let right = next[left]
        guard right >= 0, right < word.count,
          let (rank, token) = merges[key(word[left].id, word[right].id)]
        else { return }
        heap.append(Candidate(rank: rank, left: left, right: right, token: token))
        var i = heap.count - 1
        while i > 0 && heap[i] < heap[(i - 1) / 2] {
          heap.swapAt(i, (i - 1) / 2)
          i = (i - 1) / 2
        }
      }
      for i in word.indices { enqueue(i) }
      while let item = heap.first {
        let last = heap.removeLast()
        if !heap.isEmpty {
          heap[0] = last
          var i = 0
          while 2 * i + 1 < heap.count {
            var child = 2 * i + 1
            if child + 1 < heap.count && heap[child + 1] < heap[child] { child += 1 }
            guard heap[child] < heap[i] else { break }
            heap.swapAt(child, i)
            i = child
          }
        }
        let left = item.left
        let right = item.right
        guard next[left] == right,
          merges[key(word[left].id, word[right].id)]?.0 == item.rank
        else { continue }
        word[left] = Piece(id: item.token, start: word[left].start)
        next[left] = next[right]
        if next[left] < word.count { previous[next[left]] = left }
        next[right] = -1
        enqueue(previous[left])
        enqueue(left)
      }
      var i = 0
      while i < word.count {
        result.append(word[i])
        i = next[i]
      }
    }
    for (i, s) in text.unicodeScalars.enumerated() {
      let value = (s == " " ? "▁" : String(s))
      if value == "▁" {
        flush()
      } else if i == 0 {
        word.append(Piece(id: vocab[Data("▁".utf8)]!, start: base))
      }
      let bytes = Data(value.utf8)
      let ids =
        vocab[bytes].map { [$0] } ?? bytes.map { vocab[Data(String(format: "<0x%02X>", $0).utf8)]! }
      word += ids.map { Piece(id: $0, start: base + i) }
    }
    flush()
    return result
  }
  func encode(_ text: String) -> [Piece] {
    let ns = text as NSString
    var result = [Piece]()
    var offset = 0
    var cursor = 0
    for match in addedPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let part = ns.substring(
        with: NSRange(location: cursor, length: match.range.location - cursor))
      result += segment(part, offset)
      offset += part.unicodeScalars.count
      let s = ns.substring(with: match.range)
      result.append(Piece(id: added[s]!, start: offset))
      offset += s.unicodeScalars.count
      cursor = NSMaxRange(match.range)
    }
    return result + segment(ns.substring(from: cursor), offset)
  }
  func suffix(_ input: String, _ budget: Int) -> String {
    guard budget > 0 else { return "" }
    var s = input
    for _ in 0..<16 {
      let e = encode(s)
      if e.count <= budget { return s }
      s = String(s.unicodeScalars.dropFirst(max(1, e[e.count - budget].start)))
    }
    while encode(s).count > budget {
      s = String(s.unicodeScalars.dropFirst(s.unicodeScalars.count / 2 + 1))
    }
    return s
  }
  func input(_ text: String, _ context: [String: Any]) throws -> [Int] {
    func quote(_ text: String) -> String {
      var s = "\""
      for c in text.unicodeScalars {
        switch c.value {
        case 34: s += "\\\""
        case 92: s += "\\\\"
        case 8: s += "\\b"
        case 9: s += "\\t"
        case 10: s += "\\n"
        case 12: s += "\\f"
        case 13: s += "\\r"
        case 0..<32: s += String(format: "\\u%04x", c.value)
        default: s.unicodeScalars.append(c)
        }
      }
      return s + "\""
    }
    let speaker = context["currentSpeaker"] as? String ?? "Room"
    func clean(_ s: String) -> String { s.replacingOccurrences(of: "<mask>", with: " ") }
    var latest = clean(text)
    var turns = [String]()
    func state() -> String {
      "{\"previous_turns\":[" + turns.joined(separator: ",") + "],\"current_speaker\":"
        + quote(speaker) + ",\"current_utterance\":" + quote(latest) + "}"
    }
    let room = 1024 - prefix.count - 1
    var count = encode(state()).count
    while count > room {
      let budget = encode(latest).count - (count - room) - 8
      guard budget > 0 else { throw TokenError.invalidInput }
      latest = suffix(latest, budget)
      count = encode(state()).count
    }
    for t in (context["recentTurns"] as? [[String: Any]] ?? []).reversed() {
      var body = clean(t["text"] as! String)
      func turn() -> String {
        "{\"speaker\":" + quote(t["speaker"] as! String) + ",\"text\":" + quote(body)
          + ",\"handled\":" + ((t["handled"] as! Bool) ? "true" : "false") + "}"
      }
      turns.insert(turn(), at: 0)
      count = encode(state()).count
      if count <= room { continue }
      while count > room {
        let b = encode(body).count - (count - room) - 8
        if b > 0 {
          body = suffix(body, b)
          turns[0] = turn()
        } else {
          turns.removeFirst()
        }
        count = encode(state()).count
      }
      break
    }
    guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TokenError.invalidInput
    }
    return prefix + encode(state()).map(\.id) + [1]
  }
}

enum SwiftEngineConstants { static let questionType = 2 }
