import Foundation

/// Saved keyframes for a typed value flowing through a Timeline node.
/// An empty path animates a scalar; a JSON Pointer animates one field of a
/// string-encoded state object without replacing its other fields.
public struct PipelineTimelineSettings: Equatable, Sendable {
  public struct Keyframe: Equatable, Sendable {
    public var frame: Int
    public var value: PipelineValue

    public init(frame: Int, value: PipelineValue) {
      self.frame = frame
      self.value = value
    }

    public var parameterValue: PipelineValue {
      .object(["frame": .integer(Int64(frame)), "value": value])
    }
  }

  public enum Interpolation: String, Sendable {
    case hold
    case linear
    case easeIn
    case easeOut
    case easeInOut

    fileprivate func progress(at fraction: Double) -> Double {
      switch self {
      case .hold: 0
      case .linear: fraction
      case .easeIn: Self.bezier(fraction, x1: 0.42, y1: 0, x2: 1, y2: 1)
      case .easeOut: Self.bezier(fraction, x1: 0, y1: 0, x2: 0.58, y2: 1)
      case .easeInOut: Self.bezier(fraction, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
      }
    }

    /// Invert the curve's time axis before reading its value axis. These are
    /// the control points of Apple's standard easing timing functions.
    private static func bezier(
      _ fraction: Double, x1: Double, y1: Double, x2: Double, y2: Double
    ) -> Double {
      if fraction <= 0 { return 0 }
      if fraction >= 1 { return 1 }
      func coordinate(_ t: Double, _ first: Double, _ second: Double) -> Double {
        let remaining = 1 - t
        return 3 * remaining * remaining * t * first
          + 3 * remaining * t * t * second + t * t * t
      }
      var lower = 0.0
      var upper = 1.0
      for _ in 0..<28 {
        let middle = (lower + upper) / 2
        if coordinate(middle, x1, x2) < fraction {
          lower = middle
        } else {
          upper = middle
        }
      }
      return coordinate((lower + upper) / 2, y1, y2)
    }
  }

  public struct Track: Equatable, Sendable {
    public var path: String
    public var interpolation: Interpolation
    public var keyframes: [Keyframe]

    public init(path: String, interpolation: Interpolation, keyframes: [Keyframe]) {
      self.path = path
      self.interpolation = interpolation
      self.keyframes = keyframes
    }

    public var parameterValue: PipelineValue {
      .object([
        "path": .string(path),
        "interpolation": .string(interpolation.rawValue),
        "keyframes": .array(keyframes.map(\.parameterValue)),
      ])
    }

    public func value(at frame: Int) -> PipelineValue {
      guard let nextIndex = keyframes.firstIndex(where: { $0.frame >= frame }) else {
        return keyframes[keyframes.count - 1].value
      }
      let next = keyframes[nextIndex]
      if nextIndex == 0 || next.frame == frame { return next.value }
      guard interpolation != .hold,
        let first = Self.number(keyframes[nextIndex - 1].value),
        let last = Self.number(next.value)
      else { return keyframes[nextIndex - 1].value }
      let previous = keyframes[nextIndex - 1]
      let fraction = Double(frame - previous.frame) / Double(next.frame - previous.frame)
      return .number(first + (last - first) * interpolation.progress(at: fraction))
    }

    fileprivate static func number(_ value: PipelineValue) -> Double? {
      switch value {
      case .integer(let number): return Double(number)
      case .number(let number): return number
      default: return nil
      }
    }
  }

  public var frameCount: Int
  public var framesPerSecond: Double
  public var tracks: [Track]

  public init(frameCount: Int = 120, framesPerSecond: Double = 30, tracks: [Track] = []) {
    self.frameCount = frameCount
    self.framesPerSecond = framesPerSecond
    self.tracks = tracks
  }

  public init?(node: PipelineNode) {
    guard node.kind.rawValue == "control.timeline" else { return nil }
    let count: Int
    if case .integer(let value)? = node.parameters["frameCount"],
      (1...3_600).contains(value) {
      count = Int(value)
    } else if node.parameters["frameCount"] == nil {
      count = 120
    } else { return nil }
    let rate: Double
    switch node.parameters["framesPerSecond"] {
    case .number(let value)?: rate = value
    case .integer(let value)?: rate = Double(value)
    case nil: rate = 30
    default: return nil
    }
    guard rate.isFinite, (1...120).contains(rate) else { return nil }
    let savedTracks: [PipelineValue]
    if case .array(let value)? = node.parameters["tracks"] {
      savedTracks = value
    } else if node.parameters["tracks"] == nil {
      savedTracks = []
    } else { return nil }
    guard savedTracks.count <= 64 else { return nil }
    var parsed: [Track] = []
    var paths: Set<String> = []
    for savedTrack in savedTracks {
      guard case .object(let fields) = savedTrack,
        case .string(let path)? = fields["path"],
        Self.validPath(path),
        paths.insert(path).inserted,
        case .string(let interpolationName)? = fields["interpolation"],
        let interpolation = Interpolation(rawValue: interpolationName),
        case .array(let savedKeys)? = fields["keyframes"],
        !savedKeys.isEmpty, savedKeys.count <= 256 else { return nil }
      var keys: [Keyframe] = []
      for savedKey in savedKeys {
        guard case .object(let keyFields) = savedKey,
          case .integer(let frame)? = keyFields["frame"],
          frame >= 0, frame < count,
          let value = keyFields["value"],
          keys.last.map({ $0.frame < frame }) ?? (frame == 0),
          Self.valid(value),
          !path.isEmpty || Track.number(value) != nil,
          interpolation == .hold || Track.number(value) != nil
        else { return nil }
        keys.append(Keyframe(frame: Int(frame), value: value))
      }
      parsed.append(Track(path: path, interpolation: interpolation, keyframes: keys))
    }
    self.init(frameCount: count, framesPerSecond: rate, tracks: parsed)
  }

  public var parameters: [String: PipelineValue] {
    [
      "frameCount": .integer(Int64(frameCount)),
      "framesPerSecond": .number(framesPerSecond),
      "tracks": .array(tracks.map(\.parameterValue)),
    ]
  }

  /// Applies keyframes to a JSON object. Paths not owned by a track keep the
  /// incoming value from the upstream node on every frame.
  public func state(_ input: String, at frame: Int) throws -> String {
    var result = try PipelineStateJSON.canonicalObject(input)
    for track in tracks {
      guard !track.path.isEmpty else {
        throw PipelineTimelineError.invalidTrack("A state track needs a JSON Pointer path.")
      }
      result = try PipelineStateJSON.setting(result, key: track.path, to: track.value(at: frame))
    }
    return result
  }

  private static func valid(_ value: PipelineValue) -> Bool {
    switch value {
    case .number(let number): return number.isFinite
    case .array(let items): return items.allSatisfy(valid)
    case .object(let fields): return fields.values.allSatisfy(valid)
    default: return true
    }
  }

  public static func validPath(_ path: String) -> Bool {
    if path.isEmpty { return true }
    guard path.hasPrefix("/"), path.utf8.count <= 256 else { return false }
    var characters = path.makeIterator()
    while let character = characters.next() {
      if character == "~" {
        guard let escape = characters.next(), escape == "0" || escape == "1" else {
          return false
        }
      }
    }
    return true
  }
}

public enum PipelineTimelineError: Error, LocalizedError, Sendable {
  case invalidTrack(String)

  public var errorDescription: String? {
    switch self {
    case .invalidTrack(let message): message
    }
  }
}
