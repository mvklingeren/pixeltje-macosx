import Foundation
import PixeltjePipelineDomain
import Testing

@Test func timelineKeyframesOverrideOnlySelectedStateFields() throws {
  let settings = PipelineTimelineSettings(frameCount: 11, framesPerSecond: 25, tracks: [
    .init(path: "/camera/y", interpolation: .linear, keyframes: [
      .init(frame: 0, value: .number(0.2)),
      .init(frame: 10, value: .number(0.8)),
    ]),
    .init(path: "/enabled", interpolation: .hold, keyframes: [
      .init(frame: 0, value: .boolean(false)),
      .init(frame: 6, value: .boolean(true)),
    ]),
  ])
  let node = PipelineNode(id: .init(rawValue: "timeline"),
    kind: PipelineControlFlow.timelineKind, parameters: settings.parameters)
  #expect(PipelineTimelineSettings(node: node) == settings)
  let input = #"{"camera":{"x":0.4,"y":0.2},"enabled":false,"name":"live"}"#
  let middle = try settings.state(input, at: 5)
  #expect(try PipelineStateJSON.read(middle, key: "/camera/x") == .number(0.4))
  #expect(try PipelineStateJSON.read(middle, key: "/camera/y") == .number(0.5))
  #expect(try PipelineStateJSON.read(middle, key: "/enabled") == .boolean(false))
  #expect(try PipelineStateJSON.read(middle, key: "/name") == .string("live"))
  let later = try settings.state(input, at: 6)
  #expect(try PipelineStateJSON.read(later, key: "/enabled") == .boolean(true))
}

@Test func timelineRejectsOutOfOrderAndOutOfRangeKeyframes() {
  let kind = PipelineControlFlow.timelineKind
  let id = PipelineNodeID(rawValue: "timeline")
  let invalid = PipelineNode(id: id, kind: kind, parameters: [
    "frameCount": .integer(3),
    "framesPerSecond": .number(30),
    "tracks": .array([.object([
      "path": .string(""), "interpolation": .string("linear"),
      "keyframes": .array([
        .object(["frame": .integer(0), "value": .number(1)]),
        .object(["frame": .integer(3), "value": .number(4)]),
      ]),
    ])]),
  ])
  #expect(PipelineTimelineSettings(node: invalid) == nil)
}

@Test func timelineEasingSamplesEachNumericKeyframeSegment() throws {
  func track(_ interpolation: PipelineTimelineSettings.Interpolation) -> PipelineTimelineSettings.Track {
    .init(path: "", interpolation: interpolation, keyframes: [
      .init(frame: 0, value: .number(0)),
      .init(frame: 10, value: .number(10)),
      .init(frame: 20, value: .number(20)),
    ])
  }
  func number(_ value: PipelineValue) throws -> Double {
    guard case .number(let number) = value else {
      throw PipelineTimelineError.invalidTrack("Expected a numeric keyframe sample.")
    }
    return number
  }

  let easeIn = track(.easeIn)
  let easeOut = track(.easeOut)
  let easeInOut = track(.easeInOut)
  #expect(try number(easeIn.value(at: 5)) < 5)
  #expect(try number(easeOut.value(at: 5)) > 5)
  #expect(abs(try number(easeInOut.value(at: 5)) - 5) < 0.000_001)
  #expect(try number(easeInOut.value(at: 2)) < 2)
  #expect(try number(easeInOut.value(at: 8)) > 8)
  #expect(abs(try number(easeInOut.value(at: 15)) - 15) < 0.000_001)
  #expect(easeIn.value(at: 0) == .number(0))
  #expect(easeIn.value(at: 10) == .number(10))
  #expect(easeIn.value(at: 20) == .number(20))

  for interpolation in [PipelineTimelineSettings.Interpolation.easeIn,
    .easeOut, .easeInOut] {
    let settings = PipelineTimelineSettings(frameCount: 21, tracks: [track(interpolation)])
    let node = PipelineNode(id: .init(rawValue: "timeline"),
      kind: PipelineControlFlow.timelineKind, parameters: settings.parameters)
    #expect(PipelineTimelineSettings(node: node) == settings)
  }
}
