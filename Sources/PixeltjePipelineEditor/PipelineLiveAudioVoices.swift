import AVFoundation
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine

/// Plays the looping voices of a live GPU Program run. Each voice repeats one
/// sound while the program sets its loudness, playback rate and stereo
/// position every frame, which carries distance and Doppler shift for a
/// moving source such as a hovering drone.
@MainActor
final class PipelineLiveAudioVoices {
  private struct Key: Hashable {
    let nodeID: PipelineNodeID
    let slot: Int
  }

  private struct Voice {
    let url: URL
    let player: AVAudioPlayerNode
    let varispeed: AVAudioUnitVarispeed
    let mixer: AVAudioMixerNode
  }

  /// A generated clip seldom ends where it began. The loop drops its edges,
  /// where a clip fades in or out, and crossfades its tail into its head.
  private static let trimSeconds = 0.08
  private static let crossfadeSeconds = 0.3

  private let engine = AVAudioEngine()
  private var voices: [Key: Voice] = [:]
  private var loops: [URL: AVAudioPCMBuffer] = [:]
  private var latestCall = 0

  /// Applies the voices of one live call. Voices absent from it stop, so an
  /// inactive scene or a finished program falls silent.
  func apply(call: Int, voices updates: [PipelineGPUAudioVoice]) throws {
    guard call > latestCall else { return }
    latestCall = call
    var current = Set<Key>()
    for update in updates {
      let key = Key(nodeID: update.nodeID, slot: update.slot)
      current.insert(key)
      if let voice = voices[key], voice.url != update.url {
        remove(voice)
        voices[key] = nil
      }
      if voices[key] == nil {
        // A silent voice need not start until it becomes audible.
        guard update.gain > 0 else { continue }
        voices[key] = try start(update.url)
      }
      guard let voice = voices[key] else { continue }
      voice.mixer.volume = update.gain
      voice.mixer.pan = update.pan
      voice.varispeed.rate = update.rate
    }
    for key in Array(voices.keys) where !current.contains(key) {
      if let voice = voices.removeValue(forKey: key) { remove(voice) }
    }
    if voices.isEmpty, engine.isRunning { engine.stop() }
  }

  /// Silences every voice, for example while the run is paused.
  func stop() {
    for voice in voices.values { remove(voice) }
    voices = [:]
    if engine.isRunning { engine.stop() }
  }

  private func start(_ url: URL) throws -> Voice {
    let loop = try loop(for: url)
    let voice = Voice(url: url, player: AVAudioPlayerNode(),
      varispeed: AVAudioUnitVarispeed(), mixer: AVAudioMixerNode())
    engine.attach(voice.player)
    engine.attach(voice.varispeed)
    engine.attach(voice.mixer)
    // Volume and pan apply where a node joins a mixer, so each voice has a
    // submixer directly on the main mixer behind its rate change.
    engine.connect(voice.player, to: voice.varispeed, format: loop.format)
    engine.connect(voice.varispeed, to: voice.mixer, format: loop.format)
    engine.connect(voice.mixer, to: engine.mainMixerNode, format: loop.format)
    voice.mixer.volume = 0
    if !engine.isRunning {
      engine.prepare()
      try engine.start()
    }
    voice.player.scheduleBuffer(loop, at: nil, options: .loops)
    voice.player.play()
    return voice
  }

  private func remove(_ voice: Voice) {
    voice.player.stop()
    engine.detach(voice.player)
    engine.detach(voice.varispeed)
    engine.detach(voice.mixer)
  }

  private func loop(for url: URL) throws -> AVAudioPCMBuffer {
    if let cached = loops[url] { return cached }
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let length = AVAudioFrameCount(file.length)
    guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try file.read(into: source)
    let loop = Self.seamlessLoop(source) ?? source
    loops[url] = loop
    return loop
  }

  /// Output sample j < fade mixes source sample start + j, fading in, with
  /// the sample one loop length later, fading out; the rest is copied. The
  /// last output sample is then followed by the samples the first one
  /// continues, so the loop point has neither a gap nor a click.
  private static func seamlessLoop(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let rate = source.format.sampleRate
    let trim = Int(trimSeconds * rate)
    let fade = Int(crossfadeSeconds * rate)
    let usable = Int(source.frameLength) - 2 * trim
    let length = usable - fade
    guard let input = source.floatChannelData, fade > 0, length > 2 * fade,
      let loop = AVAudioPCMBuffer(pcmFormat: source.format,
        frameCapacity: AVAudioFrameCount(length)),
      let output = loop.floatChannelData else { return nil }
    loop.frameLength = AVAudioFrameCount(length)
    for channel in 0..<Int(source.format.channelCount) {
      let from = input[channel] + trim
      let to = output[channel]
      for index in 0..<fade {
        let rise = Float(index) / Float(fade)
        to[index] = from[index] * rise.squareRoot()
          + from[length + index] * (1 - rise).squareRoot()
      }
      for index in fade..<length { to[index] = from[index] }
    }
    return loop
  }
}
