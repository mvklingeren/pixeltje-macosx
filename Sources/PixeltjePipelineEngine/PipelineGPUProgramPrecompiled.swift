import CryptoKit
import Foundation
import Metal

/// Build artifacts for the bundled Haunted House example. Edited shaders
/// keep the ordinary source compiler path because their hashes no longer match.
enum PipelineGPUProgramPrecompiled {
  static func load(source: String, device: any MTLDevice)
    -> (library: any MTLLibrary, archive: (any MTLBinaryArchive)?)? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let examples = resources.appendingPathComponent("Examples", isDirectory: true)
    let prefix = "HauntedHouseProgram"
    let hashURL = examples.appendingPathComponent("\(prefix).source.sha256")
    let sourceHash = SHA256.hash(data: Data(source.utf8))
      .map { String(format: "%02x", $0) }.joined()
    guard let recorded = try? String(contentsOf: hashURL, encoding: .utf8),
      recorded.trimmingCharacters(in: .whitespacesAndNewlines)
        == sourceHash else { return nil }
    let libraryURL = examples.appendingPathComponent("\(prefix).metallib")
    guard let library = try? device.makeLibrary(URL: libraryURL) else { return nil }
    let archiveURL = examples.appendingPathComponent("\(prefix).binary.metallib")
    let descriptor = MTLBinaryArchiveDescriptor()
    descriptor.url = archiveURL
    let archive = try? device.makeBinaryArchive(descriptor: descriptor)
    return (library, archive)
  }
}
