import Foundation
import PixeltjePipelineDomain

/// Serializable controls for a workflow-supplied full-screen Metal shader.
/// Source code is supplied separately through Metal Render's source or sourceFile port.
struct PipelineMetalShaderState: Decodable {
  struct Pointer: Decodable {
    var x: Double
    var y: Double
    var engaged: Bool
    var engagedAtCall: Double

    private enum CodingKeys: String, CodingKey { case x, y, engaged, engagedAtCall }

    init(x: Double, y: Double, engaged: Bool = false, engagedAtCall: Double = 0) {
      self.x = x
      self.y = y
      self.engaged = engaged
      self.engagedAtCall = engagedAtCall
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      x = try values.decode(Double.self, forKey: .x)
      y = try values.decode(Double.self, forKey: .y)
      engaged = try values.decodeIfPresent(Bool.self, forKey: .engaged) ?? false
      engagedAtCall = try values.decodeIfPresent(Double.self, forKey: .engagedAtCall) ?? 0
    }
  }

  let fragmentFunction: String
  let width: Int
  let height: Int
  let timeSeconds: Double
  let secondsPerFrame: Double
  let pointer: Pointer

  private enum CodingKeys: String, CodingKey {
    case version, mode, fragmentFunction, width, height, timeSeconds, secondsPerFrame, pointer
  }

  init(json: String) throws {
    let canonical = try PipelineStateJSON.canonicalObject(json)
    self = try JSONDecoder().decode(Self.self, from: Data(canonical.utf8))
    _ = try PipelineMetalRenderSize(width: width, height: height)
    guard timeSeconds.isFinite, (0...1_000_000).contains(timeSeconds),
      secondsPerFrame.isFinite, (0...1).contains(secondsPerFrame),
      pointer.x.isFinite, (0...1).contains(pointer.x),
      pointer.y.isFinite, (0...1).contains(pointer.y),
      pointer.engagedAtCall.isFinite, pointer.engagedAtCall >= 0,
      timeSeconds + pointer.engagedAtCall * secondsPerFrame <= 1_000_000 else {
      throw PipelineEngineError.invalidInvocation("Metal shader time and pointer values are outside their supported ranges.")
    }
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Int.self, forKey: .version)
    guard version == 1 else {
      throw PipelineEngineError.invalidInvocation("Metal Render state version must be 1.")
    }
    let mode = try values.decode(String.self, forKey: .mode)
    guard mode == "shader" else {
      throw PipelineEngineError.invalidInvocation("Metal Render state mode must be shader.")
    }
    let name = try values.decode(String.self, forKey: .fragmentFunction)
    guard !name.isEmpty, name.utf8.count <= 128,
      name.utf8.allSatisfy({ $0 == 95 || (48...57).contains($0)
        || (65...90).contains($0) || (97...122).contains($0) }),
      let first = name.utf8.first, first == 95 || (65...90).contains(first)
        || (97...122).contains(first) else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render fragmentFunction must be a Metal identifier.")
    }
    fragmentFunction = name
    width = try values.decode(Int.self, forKey: .width)
    height = try values.decode(Int.self, forKey: .height)
    timeSeconds = try values.decodeIfPresent(Double.self, forKey: .timeSeconds) ?? 0
    secondsPerFrame = try values.decodeIfPresent(Double.self, forKey: .secondsPerFrame) ?? 0
    pointer = try values.decodeIfPresent(Pointer.self, forKey: .pointer)
      ?? Pointer(x: 0.5, y: 0.5)
  }
}
