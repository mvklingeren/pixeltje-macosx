import CryptoKit
import Foundation

/// A bounded Radiance RGBE image, kept in linear light for Metal environment
/// sampling. File Path nodes supply the location; pixels are never saved in a
/// pipeline document.
struct PipelineRadianceHDR: Sendable {
  let width: Int
  let height: Int
  let rgba: [Float]
  let fingerprint: String

  static func url(for path: String, sourceMediaRoot: URL?) throws -> URL {
    guard !path.isEmpty, !path.contains("\0") else {
      throw PipelineEngineError.invalidInvocation("GPU Program file texture needs a path.")
    }
    if path.hasPrefix("~/") {
      return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
    }
    if (path as NSString).isAbsolutePath {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    guard let sourceMediaRoot else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program file texture needs a workflow folder for a relative path.")
    }
    return sourceMediaRoot.appendingPathComponent(path).standardizedFileURL
  }

  static func load(at url: URL) throws -> Self {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber,
      (1...33_554_432).contains(size.intValue) else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program file texture must be a Radiance HDR file of at most 32 MiB.")
    }
    let data = try Data(contentsOf: url)
    guard data.count <= 33_554_432 else {
      throw PipelineEngineError.invalidInvocation("GPU Program HDR file exceeds 32 MiB.")
    }
    return try decode(data)
  }

  static func decode(_ data: Data) throws -> Self {
    func invalid(_ reason: String) -> PipelineEngineError {
      .invalidInvocation("GPU Program Radiance HDR: \(reason)")
    }
    let bytes = [UInt8](data)
    var offset = 0
    func line() throws -> String {
      let start = offset
      while offset < bytes.count && bytes[offset] != 10 && offset - start <= 4096 {
        offset += 1
      }
      guard offset < bytes.count, offset - start <= 4096,
        let text = String(bytes: bytes[start..<offset], encoding: .ascii) else {
        throw invalid("invalid or oversized header.")
      }
      offset += 1
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let magic = try line()
    guard magic == "#?RADIANCE" || magic == "#?RGBE" else {
      throw invalid("missing Radiance header.")
    }
    var format = false
    while true {
      let entry = try line()
      if entry.isEmpty { break }
      if entry == "FORMAT=32-bit_rle_rgbe" { format = true }
    }
    guard format else { throw invalid("expected 32-bit RLE RGBE format.") }
    let dimensions = try line().split(whereSeparator: \.isWhitespace).map(String.init)
    guard dimensions.count == 4,
      ["-Y", "+Y"].contains(dimensions[0]),
      ["+X", "-X"].contains(dimensions[2]),
      let height = Int(dimensions[1]), let width = Int(dimensions[3]),
      (8...4096).contains(width), (1...4096).contains(height),
      width * height <= 4_194_304 else {
      throw invalid("unsupported dimensions or orientation.")
    }
    var rgba = [Float](repeating: 1, count: width * height * 4)
    var channels = [UInt8](repeating: 0, count: width * 4)
    let scales = (0...255).map { Float(pow(2.0, Double($0 - 136))) }
    for scanline in 0..<height {
      guard offset + 4 <= bytes.count, bytes[offset] == 2,
        bytes[offset + 1] == 2,
        Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3]) == width else {
        throw invalid("unsupported or truncated RLE scanline.")
      }
      offset += 4
      for channel in 0..<4 {
        var x = 0
        while x < width {
          guard offset < bytes.count else { throw invalid("truncated RLE data.") }
          let code = Int(bytes[offset]); offset += 1
          let count = code > 128 ? code - 128 : code
          guard count > 0, x + count <= width else {
            throw invalid("invalid RLE run length.")
          }
          if code > 128 {
            guard offset < bytes.count else { throw invalid("truncated RLE run.") }
            let value = bytes[offset]; offset += 1
            for i in 0..<count { channels[channel * width + x + i] = value }
          } else {
            guard offset + count <= bytes.count else {
              throw invalid("truncated RLE literals.")
            }
            for i in 0..<count {
              channels[channel * width + x + i] = bytes[offset + i]
            }
            offset += count
          }
          x += count
        }
      }
      let y = dimensions[0] == "-Y" ? scanline : height - 1 - scanline
      for x in 0..<width {
        let column = dimensions[2] == "+X" ? x : width - 1 - x
        let target = (y * width + column) * 4
        let exponent = Int(channels[3 * width + x])
        if exponent == 0 {
          rgba[target] = 0; rgba[target + 1] = 0; rgba[target + 2] = 0
        } else {
          let scale = scales[exponent]
          for channel in 0..<3 {
            rgba[target + channel] = Float(channels[channel * width + x]) * scale
          }
        }
      }
    }
    let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return Self(width: width, height: height, rgba: rgba, fingerprint: fingerprint)
  }
}
