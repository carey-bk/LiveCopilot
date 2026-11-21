import CryptoKit
import Darwin
import Foundation

#if MAS_COREML
private let engineName = "coreml"
#else
private let engineName = "mlx-swift"
#endif

private enum Failure: Error { case invalid }

private struct Receipt: Decodable, Equatable {
  let weight_bytes: Int64
  let schema: Int
  let backend, precision, source_sha256: String
  let files: [String: String]
}

private struct Context: Decodable {
  struct Turn: Decodable {
    let speaker, text: String
    let handled: Bool
  }
  let currentSpeaker: String
  let recentTurns: [Turn]

  static func parse(_ raw: String) throws -> [String: Any] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [:] }
    if !trimmed.hasPrefix("{") {
      return ["recentTurns": [["speaker": "Unknown", "text": raw, "handled": false]]]
    }
    let data = Data(raw.utf8)
    let context = try JSONDecoder().decode(Self.self, from: data)
    guard context.currentSpeaker.unicodeScalars.count <= 32, context.recentTurns.count <= 80,
      context.recentTurns.allSatisfy({ $0.speaker.unicodeScalars.count <= 32 }),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object.count == 2,
      let turns = object["recentTurns"] as? [[String: Any]], turns.allSatisfy({ $0.count == 3 })
    else { throw Failure.invalid }
    return object
  }
}

private func verify(_ directory: URL, resources: URL, precision: String) throws {
  #if MAS_COREML
  guard ["fp16", "w8", "e8w16", "e4w8", "w4"].contains(precision) else { throw Failure.invalid }
  #else
  guard precision == "fp16" || precision == "e8" else { throw Failure.invalid }
  #endif
  let decoder = JSONDecoder()
  let pinned = try decoder.decode(
    Receipt.self,
    from: Data(
      contentsOf:
        resources.appendingPathComponent("native-" + precision + ".json")))
  let actual = try decoder.decode(
    Receipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt.json")))
  guard actual == pinned, actual.backend == engineName, actual.schema == 2,
    actual.precision == precision
  else { throw Failure.invalid }
  for (name, digest) in pinned.files {
    let url = directory.appendingPathComponent(name)
    let resolved = url.resolvingSymlinksInPath()
    guard resolved.path == directory.resolvingSymlinksInPath().appendingPathComponent(name).path,
      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    else { throw Failure.invalid }
    let stream = try FileHandle(forReadingFrom: url)
    defer { try? stream.close() }
    var hash = SHA256()
    while try autoreleasepool(invoking: {
      guard let block = try stream.read(upToCount: 1 << 20), !block.isEmpty else { return false }
      hash.update(data: block)
      return true
    }) {}
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
      throw Failure.invalid
    }
  }
}

private func serve(_ channel: FileHandle) throws {
  func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value)
    bytes.append(10)
    try channel.write(contentsOf: bytes)
  }
  let args = CommandLine.arguments
  guard args.count == 4 else { throw Failure.invalid }
  let directory = URL(fileURLWithPath: args[1])
  let resources = URL(fileURLWithPath: args[2])
  let tokenizer: Tokenizer
  #if MAS_COREML
  let engine: CoreMLEngine
  #else
  let engine: SwiftEngine
  #endif
  do {
    try verify(directory, resources: resources, precision: args[3])
    tokenizer = try autoreleasepool {
      try Tokenizer(
        directory.appendingPathComponent("tokenizer/tokenizer.json").path,
        resources.appendingPathComponent("native-question.json").path)
    }
    #if MAS_COREML
    if args[3] == "fp16" {
      engine = try CoreMLEngine(directory.appendingPathComponent("fp16.mlmodelc"))
    } else {
      engine = try CoreMLEngine(
        directory.appendingPathComponent("encoder.mlmodelc"),
        embeddings: directory.appendingPathComponent("embeddings.bin"))
    }
    #else
    engine = try SwiftEngine(directory.appendingPathComponent("model.safetensors"))
    #endif
    let ids = try tokenizer.input("The meeting starts at nine.", [:])
    let warmup = try engine.score(ids, tokenizer.markers)
    guard warmup.isFinite, (0...1).contains(warmup) else { throw Failure.invalid }
  } catch {
    try emit(["ready": false, "error": "load_failed"])
    throw error
  }
  try emit(["ready": true, "protocol": 1, "backend": engineName, "precision": args[3]])
  var bytes = [UInt8](repeating: 0, count: 8192)
  var line = Data()
  while true {
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    if count < 0 && errno == EINTR { continue }
    if count == 0 && line.isEmpty { return }
    guard count > 0 else { throw Failure.invalid }
    for byte in bytes.prefix(count) {
      if byte != 10 {
        guard line.count < 131071 else {
          try emit(["error": "invalid_request"])
          throw Failure.invalid
        }
        line.append(byte)
        continue
      }
      try autoreleasepool {
        var identifier: Any = NSNull()
        do {
          guard String(data: line, encoding: .utf8) != nil,
            let request = try JSONSerialization.jsonObject(with: line) as? [String: String],
            request.count == 4, request["op"] == "predict", let id = request["id"],
            (1...64).contains(id.utf8.count),
            id.utf8.allSatisfy({
              (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45
            }), let text = request["text"], let context = request["context"],
            text.utf8.count <= 65536, context.utf8.count <= 65536
          else { throw Failure.invalid }
          identifier = id
          let ids = try tokenizer.input(text, Context.parse(context))
          let score = Double(try engine.score(ids, tokenizer.markers))
          guard score.isFinite, (0...1).contains(score) else { throw Failure.invalid }
          try emit([
            "id": id, "score": (score * 10000).rounded(.toNearestOrEven) / 10000,
            "input_tokens": ids.count,
          ])
        } catch {
          try emit(["id": identifier, "error": "prediction_failed"])
        }
      }
      line.removeAll(keepingCapacity: true)
    }
  }
}

let protocolFD = dup(STDOUT_FILENO)
let null = open("/dev/null", O_WRONLY)
guard protocolFD >= 0, null >= 0, dup2(null, STDOUT_FILENO) >= 0,
  dup2(null, STDERR_FILENO) >= 0
else { exit(2) }
close(null)
guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { exit(2) }
_ = nice(10)
do { try serve(FileHandle(fileDescriptor: protocolFD, closeOnDealloc: true)) } catch { exit(2) }
