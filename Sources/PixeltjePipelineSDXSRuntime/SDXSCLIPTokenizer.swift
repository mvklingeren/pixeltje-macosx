import Foundation

/// CLIP's byte-level BPE vocabulary and end-of-word merge rule for SDXS prompts.
struct SDXSCLIPTokenizer: Sendable {
  private struct Pair: Hashable, Sendable {
    let first: String
    let second: String
  }

  private let vocabulary: [String: Int32]
  private let ranks: [Pair: Int]
  private let byteCharacters: [String]
  private let bos: Int32
  private let eos: Int32

  init(directory: URL) throws {
    let vocabURL = directory.appendingPathComponent("vocab.json")
    let mergesURL = directory.appendingPathComponent("merges.txt")
    let data = try Data(contentsOf: vocabURL)
    guard let rawVocabulary = try JSONSerialization.jsonObject(with: data) as? [String: Int],
      let bos = rawVocabulary["<|startoftext|>"],
      let eos = rawVocabulary["<|endoftext|>"]
    else { throw TokenizerError.invalidVocabulary }
    vocabulary = rawVocabulary.mapValues(Int32.init)
    self.bos = Int32(bos)
    self.eos = Int32(eos)

    let lines = try String(contentsOf: mergesURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
    var ranks: [Pair: Int] = [:]
    for line in lines where !line.hasPrefix("#") {
      let pieces = line.split(whereSeparator: \.isWhitespace)
      guard pieces.count == 2 else { continue }
      ranks[Pair(first: String(pieces[0]), second: String(pieces[1]))] = ranks.count
    }
    guard !ranks.isEmpty else { throw TokenizerError.invalidMerges }
    self.ranks = ranks

    let visible = Array(33...126) + Array(161...172) + Array(174...255)
    var unicodeScalars = visible
    let visibleSet = Set(visible)
    var next = 256
    for byte in 0...255 where !visibleSet.contains(byte) {
      unicodeScalars.append(next)
      next += 1
    }
    var characters = [String](repeating: "", count: 256)
    for (byte, scalar) in zip(visible + (0...255).filter { !visibleSet.contains($0) },
      unicodeScalars) {
      characters[byte] = String(UnicodeScalar(scalar)!)
    }
    byteCharacters = characters
  }

  func encode(_ prompt: String, length: Int) -> [Int32] {
    let clean = prompt.precomposedStringWithCanonicalMapping.lowercased()
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let expression = try! NSRegularExpression(
      pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#)
    let range = NSRange(clean.startIndex..<clean.endIndex, in: clean)
    var ids: [Int32] = [bos]
    for match in expression.matches(in: clean, range: range) {
      guard let range = Range(match.range, in: clean) else { continue }
      let word = String(clean[range])
      if word == "<|startoftext|>" { ids.append(bos); continue }
      if word == "<|endoftext|>" { ids.append(eos); continue }
      var symbols = word.utf8.map { byteCharacters[Int($0)] }
      guard !symbols.isEmpty else { continue }
      symbols[symbols.count - 1] += "</w>"
      while symbols.count > 1 {
        var bestIndex: Int?
        var bestRank = Int.max
        for index in 0..<(symbols.count - 1) {
          if let rank = ranks[Pair(first: symbols[index], second: symbols[index + 1])],
            rank < bestRank {
            bestIndex = index
            bestRank = rank
          }
        }
        guard let index = bestIndex else { break }
        symbols[index] += symbols.remove(at: index + 1)
      }
      ids += symbols.map { vocabulary[$0] ?? eos }
    }
    ids = Array(ids.prefix(max(length - 1, 0)))
    ids.append(eos)
    if ids.count < length {
      ids += Array(repeating: eos, count: length - ids.count)
    }
    return ids
  }
}

private enum TokenizerError: LocalizedError {
  case invalidVocabulary
  case invalidMerges

  var errorDescription: String? {
    switch self {
    case .invalidVocabulary: "The SDXS CLIP vocabulary is invalid."
    case .invalidMerges: "The SDXS CLIP merge list is invalid."
    }
  }
}
