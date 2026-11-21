#if MAS_COREML
#if arch(x86_64)
import Accelerate
#endif
import CoreML
import Darwin
import Foundation

/// Read-only, fixed-width rows. Decoding touches only the rows requested by the tokenizer.
private final class QuantizedEmbeddings {
  private static let magic = Array("LCEMBED1".utf8)
  private let mapping: UnsafeMutableRawPointer
  private let length: Int
  private let bits: Int
  private let group: Int
  private let rowBytes: Int
  private let scaleBytes: Int
  private let offsetBytes: Int
  private static let headerBytes = 32
  private static let rows = 256_000
  private static let width = 768

  init(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw TokenError.invalidInput }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size >= Self.headerBytes, info.st_size <= 220_000_000
    else { throw TokenError.invalidInput }
    let size = Int(info.st_size)
    guard let memory = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), memory != MAP_FAILED
    else { throw TokenError.invalidInput }
    var valid = false
    defer { if !valid { munmap(memory, size) } }
    func field(_ index: Int) -> Int {
      Int(UInt32(littleEndian: memory.load(fromByteOffset: 8 + index * 4, as: UInt32.self)))
    }
    let bits = field(2)
    let group = field(3)
    let hasOffsets = field(4) == 1
    guard UnsafeRawBufferPointer(start: memory, count: 8).elementsEqual(Self.magic),
          field(0) == Self.rows, field(1) == Self.width, bits == 4 || bits == 8,
          group == 32 || group == 64, field(4) == 0 || (bits == 4 && hasOffsets), field(5) == 0
    else { throw TokenError.invalidInput }
    let scaleBytes = Self.width / group * 2
    let offsetBytes = hasOffsets ? Self.width / group : 0
    let rowBytes = scaleBytes + offsetBytes + Self.width * bits / 8
    guard size == Self.headerBytes + Self.rows * rowBytes else { throw TokenError.invalidInput }
    self.mapping = memory
    self.length = size
    self.bits = bits
    self.group = group
    self.rowBytes = rowBytes
    self.scaleBytes = scaleBytes
    self.offsetBytes = offsetBytes
    valid = true
  }

  deinit { munmap(mapping, length) }

  #if arch(arm64)
  private typealias GatheredElement = Float16

  private static func scaleValue(_ bits: UInt16) -> Float {
    Float(Float16(bitPattern: bits))
  }
  #else
  private typealias GatheredElement = Float

  private static func scaleValue(_ bits: UInt16) -> Float {
    // The verified file stores positive, finite binary16 scales.
    if bits < 0x0400 { return Float(bits) * 0x1p-24 }
    let binary32 = (UInt32(bits) << 13) + 0x3800_0000
    return Float(bitPattern: binary32)
  }
  #endif

  private func gather(_ ids: [Int], into output: UnsafeMutableBufferPointer<GatheredElement>,
                      rowStride: Int, columnStride: Int) {
    for (index, id) in ids.enumerated() {
      let row = mapping.advanced(by: Self.headerBytes + id * rowBytes)
      let offsets = row.advanced(by: scaleBytes).assumingMemoryBound(to: Int8.self)
      let codes = row.advanced(by: scaleBytes + offsetBytes).assumingMemoryBound(to: UInt8.self)
      let base = index * rowStride
      for start in stride(from: 0, to: Self.width, by: group) {
        let groupIndex = start / group
        let scaleBits = UInt16(littleEndian: row.load(fromByteOffset: groupIndex * 2, as: UInt16.self))
        let scale = Self.scaleValue(scaleBits)
        if bits == 8 {
          for column in start..<(start + group) {
            let code = Int8(bitPattern: codes[column])
            output[base + column * columnStride] = GatheredElement(Float(code) * scale)
          }
        } else {
          let offset = offsetBytes == 0 ? 0 : Float(offsets[groupIndex])
          for column in stride(from: start, to: start + group, by: 2) {
            let packed = codes[column / 2]
            let low = Int8(bitPattern: packed << 4) >> 4
            let high = Int8(bitPattern: packed) >> 4
            output[base + column * columnStride] = GatheredElement((Float(low) - offset) * scale)
            output[base + (column + 1) * columnStride] = GatheredElement((Float(high) - offset) * scale)
          }
        }
      }
    }
  }

  func features(for ids: [Int]) throws -> MLMultiArray {
    guard (100...1024).contains(ids.count),
          ids.allSatisfy({ (0..<Self.rows).contains($0) }) else { throw TokenError.invalidInput }
    let tensor = try MLMultiArray(
      shape: [NSNumber(value: ids.count), NSNumber(value: Self.width)], dataType: .float16)
    #if arch(arm64)
    tensor.withUnsafeMutableBytes { output, strides in
      gather(ids, into: output.bindMemory(to: Float16.self),
             rowStride: strides[0], columnStride: strides[1])
    }
    #else
    // Swift's Float16 arithmetic is unavailable on Intel macOS. Convert the
    // gathered FP32 scratch buffer to binary16 with Accelerate in one pass.
    var scratch = [Float](repeating: 0, count: ids.count * Self.width)
    try scratch.withUnsafeMutableBufferPointer { input in
      gather(ids, into: input, rowStride: Self.width, columnStride: 1)
      try tensor.withUnsafeMutableBytes { output, strides in
        guard strides[1] == 1 else { throw TokenError.invalidInput }
        var source = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(ids.count),
                                   width: vImagePixelCount(Self.width),
                                   rowBytes: Self.width * MemoryLayout<Float>.stride)
        var destination = vImage_Buffer(data: output.baseAddress, height: source.height,
                                        width: source.width, rowBytes: strides[0] * MemoryLayout<UInt16>.stride)
        guard vImageConvert_PlanarFtoPlanar16F(&source, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { throw TokenError.invalidInput }
      }
    }
    #endif
    return tensor
  }
}

struct CoreMLEngine {
  private let model: MLModel
  private let embeddings: QuantizedEmbeddings?

  init(_ url: URL, embeddings embeddingsURL: URL? = nil) throws {
    embeddings = try embeddingsURL.map { try QuantizedEmbeddings($0) }
    let config = MLModelConfiguration()
    #if MAS_MEASUREMENT
    switch ProcessInfo.processInfo.environment["LC_MEASURE_UNITS"] {
    case "cpu": config.computeUnits = .cpuOnly
    case "ane": config.computeUnits = .cpuAndNeuralEngine
    case "gpu": config.computeUnits = .cpuAndGPU
    default: config.computeUnits = .all
    }
    #elseif MAS_GPU_COMPARISON
    config.computeUnits = .cpuAndGPU
    #else
    config.computeUnits = embeddings == nil ? .all : .cpuAndGPU
    #endif
    model = try MLModel(contentsOf: url, configuration: config)
  }

  func score(_ ids: [Int], _ markers: [Int]) throws -> Float {
    let input: MLMultiArray
    if let embeddings {
      input = try embeddings.features(for: ids)
    } else {
      input = try MLMultiArray(shape: [NSNumber(value: ids.count)], dataType: .int32)
      for i in ids.indices { input[i] = NSNumber(value: ids[i]) }
    }
    let features = try MLDictionaryFeatureProvider(dictionary: ["ids": input])
    let output = try model.prediction(from: features)
    guard let probabilities = output.featureValue(for: "prob")?.multiArrayValue,
          probabilities.count == 2 else { throw TokenError.invalidInput }
    return probabilities[1].floatValue
  }
}
#endif
