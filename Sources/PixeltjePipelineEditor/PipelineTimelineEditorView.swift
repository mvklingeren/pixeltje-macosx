import PixeltjePipelineDomain
import PixeltjePipelineEngine
import SwiftUI

/// The bottom editor is the selected Timeline node's saved keyframe data.
struct PipelineTimelineEditorView: View {
  @ObservedObject var model: PipelineEditorModel
  let node: PipelineNode

  @State private var playhead = 0
  @State private var newPath = ""
  @State private var expandedTracks: Set<String> = []

  private let trackColumnWidth: CGFloat = 240

  private var settings: PipelineTimelineSettings? {
    PipelineTimelineSettings(node: node)
  }

  var body: some View {
    Group {
      if let settings {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 14) {
            Label("Timeline", systemImage: "timeline.selection")
              .font(.headline)
            Stepper("Frames: \(settings.frameCount)", value: Binding(
              get: { settings.frameCount },
              set: { count in
                model.setParameter(.integer(Int64(count)), named: "frameCount", for: node.id)
                playhead = min(playhead, count - 1)
              }), in: minimumFrameCount(settings)...3_600)
              .fixedSize()
            HStack(spacing: 4) {
              Text("FPS")
              TextField("FPS", value: Binding(
                get: { settings.framesPerSecond },
                set: { rate in
                  guard rate.isFinite, (1...120).contains(rate) else { return }
                  model.setParameter(.number(rate), named: "framesPerSecond", for: node.id)
                }), format: .number)
                .frame(width: 54)
            }
            Spacer()
            Button("Preview Frame") {
              model.previewTimelineFrame(min(playhead, settings.frameCount - 1), for: node.id)
            }
              .disabled(model.isRunning)
          }
          HStack(spacing: 8) {
            TextField("JSON Pointer, or empty for a scalar", text: $newPath)
              .textFieldStyle(.roundedBorder)
            Button("Add Track") { addTrack(settings) }
              .disabled(settings.tracks.count >= 64
                || !PipelineTimelineSettings.validPath(newPath)
                || settings.tracks.contains(where: { $0.path == newPath }))
          }
          HStack(spacing: 0) {
            HStack(spacing: 8) {
              Text("Tracks")
                .font(.caption.weight(.semibold))
              Spacer(minLength: 0)
              Stepper(value: $playhead, in: 0...(settings.frameCount - 1)) {
                Text("\(playhead)").monospacedDigit()
              }
              .fixedSize()
              .help("Current frame")
              Text(String(format: "%.2f s", Double(playhead) / settings.framesPerSecond))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(width: trackColumnWidth)
            ruler(settings: settings)
          }
          .frame(height: 30)
          ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
              if settings.tracks.isEmpty {
                Text("Add a track to keyframe the incoming value. Untouched state fields stay live.")
                  .foregroundStyle(.secondary)
                  .padding(8)
              }
              ForEach(settings.tracks.indices, id: \.self) { trackIndex in
                trackRow(settings.tracks[trackIndex], at: trackIndex, settings: settings)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .scrollIndicators(.visible, axes: .vertical)
          .frame(maxHeight: .infinity)
        }
        .padding(12)
        .disabled(model.isRunning)
        .onChange(of: settings.frameCount) { _, count in
          playhead = min(playhead, count - 1)
        }
      } else {
        Text("Timeline settings are invalid.")
          .foregroundStyle(.red)
          .padding()
      }
    }
    .frame(minHeight: 240, maxHeight: 320)
  }

  private func ruler(settings: PipelineTimelineSettings) -> some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      ZStack(alignment: .leading) {
        Color.secondary.opacity(0.07)
        ForEach(tickFrames(frameCount: settings.frameCount, width: width), id: \.self) { frame in
          VStack(spacing: 1) {
            Text("\(frame)")
              .font(.system(size: 10).monospacedDigit())
              .foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1, height: 6)
          }
          .position(x: frameX(frame, frameCount: settings.frameCount, width: width), y: 15)
        }
        Rectangle()
          .fill(Color.accentColor)
          .frame(width: 2, height: 30)
          .offset(x: frameX(playhead, frameCount: settings.frameCount, width: width) - 1)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { value in
        playhead = frame(at: value.location.x, frameCount: settings.frameCount, width: width)
      })
      .help("Drag to choose a frame")
    }
    .accessibilityLabel("Timeline ruler")
    .accessibilityValue("Frame \(playhead)")
  }

  private func trackRow(
    _ track: PipelineTimelineSettings.Track, at index: Int,
    settings: PipelineTimelineSettings
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 0) {
        Button {
          if !expandedTracks.insert(track.path).inserted {
            expandedTracks.remove(track.path)
          }
        } label: {
          HStack(spacing: 7) {
            Image(systemName: expandedTracks.contains(track.path) ? "chevron.down" : "chevron.right")
              .font(.caption.weight(.semibold))
              .frame(width: 12)
            Text(track.path.isEmpty ? "Value" : track.path)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(interpolationTitle(track.interpolation))
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\(track.keyframes.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 8)
          .frame(width: trackColumnWidth, height: 32)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(track.path.isEmpty ? "Value" : track.path) · \(track.keyframes.count) keyframes. Expand to edit.")
        trackTimeline(track, settings: settings)
          .frame(height: 32)
      }
      if expandedTracks.contains(track.path) {
        trackDetails(track, at: index, settings: settings)
          .padding(.horizontal, 8)
          .padding(.bottom, 6)
      }
    }
    .background(index.isMultiple(of: 2) ? Color.secondary.opacity(0.035) : Color.clear)
  }

  private func trackTimeline(
    _ track: PipelineTimelineSettings.Track, settings: PipelineTimelineSettings
  ) -> some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.14))
          .frame(width: max(0, width - 16), height: 12)
          .offset(x: 8)
        if track.keyframes.count > 1,
          let first = track.keyframes.first,
          let last = track.keyframes.last {
          Capsule()
            .fill(Color.accentColor.opacity(0.28))
            .frame(width: max(0, frameX(last.frame, frameCount: settings.frameCount, width: width)
              - frameX(first.frame, frameCount: settings.frameCount, width: width)), height: 12)
            .offset(x: frameX(first.frame, frameCount: settings.frameCount, width: width))
        }
        Rectangle()
          .fill(Color.accentColor.opacity(0.8))
          .frame(width: 1, height: 32)
          .offset(x: frameX(playhead, frameCount: settings.frameCount, width: width))
        ForEach(track.keyframes.indices, id: \.self) { keyIndex in
          let key = track.keyframes[keyIndex]
          Button { playhead = key.frame } label: {
            Image(systemName: "diamond.fill")
              .font(.system(size: key.frame == playhead ? 13 : 11))
              .foregroundStyle(Color.accentColor)
              .frame(width: 20, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .position(x: frameX(key.frame, frameCount: settings.frameCount, width: width), y: 16)
          .help("Keyframe at frame \(key.frame)")
        }
      }
    }
  }

  private func trackDetails(
    _ track: PipelineTimelineSettings.Track, at index: Int,
    settings: PipelineTimelineSettings
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Picker("Interpolation", selection: Binding(
          get: { track.interpolation },
          set: { interpolation in
            updateTrack(at: index) { $0.interpolation = interpolation }
          })) {
          Text("Hold").tag(PipelineTimelineSettings.Interpolation.hold)
          Text("Linear").tag(PipelineTimelineSettings.Interpolation.linear)
          Text("Ease In").tag(PipelineTimelineSettings.Interpolation.easeIn)
          Text("Ease Out").tag(PipelineTimelineSettings.Interpolation.easeOut)
          Text("Ease In/Out").tag(PipelineTimelineSettings.Interpolation.easeInOut)
        }
        .labelsHidden()
        .frame(width: 128)
        .disabled(!track.keyframes.allSatisfy { numeric($0.value) != nil })
        Button("Add Keyframe") { addKeyframe(at: index, settings: settings) }
          .disabled(track.keyframes.contains(where: { $0.frame == playhead })
            || track.keyframes.count >= 256)
        Spacer()
        Button(role: .destructive) { removeTrack(at: index) } label: {
          Image(systemName: "trash")
        }
        .help("Remove track")
      }
      ForEach(track.keyframes.indices, id: \.self) { keyIndex in
        let key = track.keyframes[keyIndex]
        HStack(spacing: 8) {
          Stepper("Frame \(key.frame)", value: Binding(
            get: { key.frame },
            set: { frame in
              updateTrack(at: index) { $0.keyframes[keyIndex].frame = frame }
            }), in: frameRange(for: keyIndex, track: track, frameCount: settings.frameCount))
            .disabled(keyIndex == 0)
            .frame(width: 135, alignment: .leading)
          if let value = numeric(key.value) {
            TextField("Value", value: Binding(
              get: { value },
              set: { number in
                guard number.isFinite else { return }
                updateTrack(at: index) { $0.keyframes[keyIndex].value = .number(number) }
              }), format: .number)
              .frame(width: 100)
          } else if case .boolean(let value) = key.value {
            Toggle("On", isOn: Binding(
              get: { value },
              set: { enabled in
                updateTrack(at: index) { $0.keyframes[keyIndex].value = .boolean(enabled) }
              }))
              .frame(width: 100)
          } else if case .string(let value) = key.value {
            TextField("Value", text: Binding(
              get: { value },
              set: { text in
                updateTrack(at: index) { $0.keyframes[keyIndex].value = .string(text) }
              }))
              .frame(width: 150)
          } else {
            Text("Complex value").foregroundStyle(.secondary)
          }
          if keyIndex > 0 {
            Button(role: .destructive) { removeKeyframe(track: index, key: keyIndex) } label: {
              Image(systemName: "minus.circle")
            }
            .help("Remove keyframe")
          }
        }
        .font(.caption)
      }
    }
    .padding(8)
    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
  }

  private func frameX(_ frame: Int, frameCount: Int, width: CGFloat) -> CGFloat {
    8 + CGFloat(min(max(frame, 0), frameCount - 1))
      / CGFloat(max(1, frameCount - 1)) * max(0, width - 16)
  }

  private func frame(at x: CGFloat, frameCount: Int, width: CGFloat) -> Int {
    let fraction = min(1, max(0, (x - 8) / max(1, width - 16)))
    return Int((fraction * CGFloat(frameCount - 1)).rounded())
  }

  private func tickFrames(frameCount: Int, width: CGFloat) -> [Int] {
    let span = Double(max(1, frameCount - 1))
    let usableWidth = Double(max(1, width - 16))
    let steps = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000]
    let step = steps.first { Double($0) * usableWidth / span >= 56 } ?? 5_000
    return Array(Swift.stride(from: 0, to: frameCount, by: step))
  }

  private func minimumFrameCount(_ settings: PipelineTimelineSettings) -> Int {
    max(1, settings.tracks.flatMap(\.keyframes).map(\.frame).max().map { $0 + 1 } ?? 1)
  }

  private func frameRange(
    for index: Int, track: PipelineTimelineSettings.Track, frameCount: Int
  ) -> ClosedRange<Int> {
    if index == 0 { return 0...0 }
    let lower = track.keyframes[index - 1].frame + 1
    let upper = index + 1 < track.keyframes.count
      ? track.keyframes[index + 1].frame - 1 : frameCount - 1
    return lower...max(lower, upper)
  }

  private func numeric(_ value: PipelineValue) -> Double? {
    switch value {
    case .integer(let integer): Double(integer)
    case .number(let number): number
    default: nil
    }
  }

  private func interpolationTitle(_ interpolation: PipelineTimelineSettings.Interpolation) -> String {
    switch interpolation {
    case .hold: "Hold"
    case .linear: "Linear"
    case .easeIn: "Ease In"
    case .easeOut: "Ease Out"
    case .easeInOut: "Ease In/Out"
    }
  }

  private func addTrack(_ settings: PipelineTimelineSettings) {
    var tracks = settings.tracks
    let initial = startingValue(for: newPath)
    tracks.append(.init(path: newPath,
      interpolation: numeric(initial) == nil ? .hold : .linear,
      keyframes: [.init(frame: 0, value: initial)]))
    model.setTimelineTracks(tracks, for: node.id)
    newPath = ""
  }

  private func startingValue(for path: String) -> PipelineValue {
    guard let connection = model.document.connections.first(where: {
      $0.input == .init(nodeID: node.id, port: "value")
    }), let source = model.document.nodes.first(where: {
      $0.id == connection.output.nodeID
    }) else { return .number(0) }
    if path.isEmpty,
      (source.kind == .primitiveInt || source.kind == .primitiveFloat),
      let value = source.parameters["value"] {
      return value
    }
    if source.kind == .stateInput, !path.isEmpty,
      case .string(let text)? = source.parameters["initialState"],
      let value = try? PipelineStateJSON.read(text, key: path) {
      return value
    }
    return .number(0)
  }

  private func updateTrack(
    at index: Int, _ edit: (inout PipelineTimelineSettings.Track) -> Void
  ) {
    guard var tracks = settings?.tracks, tracks.indices.contains(index) else { return }
    edit(&tracks[index])
    model.setTimelineTracks(tracks, for: node.id)
  }

  private func removeTrack(at index: Int) {
    guard var tracks = settings?.tracks, tracks.indices.contains(index) else { return }
    tracks.remove(at: index)
    model.setTimelineTracks(tracks, for: node.id)
  }

  private func addKeyframe(at index: Int, settings: PipelineTimelineSettings) {
    updateTrack(at: index) { track in
      let value = track.value(at: playhead)
      track.keyframes.append(.init(frame: playhead, value: value))
      track.keyframes.sort { $0.frame < $1.frame }
    }
  }

  private func removeKeyframe(track index: Int, key: Int) {
    updateTrack(at: index) { $0.keyframes.remove(at: key) }
  }
}
