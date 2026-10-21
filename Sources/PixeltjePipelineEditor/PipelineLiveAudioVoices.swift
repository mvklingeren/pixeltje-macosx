import AVFoundation
import Foundation
import Synchronization
import PixeltjePipelineDomain
import PixeltjePipelineEngine

/// Plays the looping voices of a live GPU Program run. Each voice repeats one
/// sound, or synthesizes one live, while the program sets its loudness,
/// playback rate and stereo position every frame, which carries distance and
/// Doppler shift for a moving source such as a hovering drone.
@MainActor
final class PipelineLiveAudioVoices {
  private struct Key: Hashable {
    let nodeID: PipelineNodeID
    let slot: Int
  }

  private struct Voice {
    let source: PipelineGPUAudioVoice.Source
    let nodes: [AVAudioNode]
    let update: (PipelineGPUAudioVoice) -> Void
  }

  /// A generated clip seldom ends where it began. The loop drops its edges,
  /// where a clip fades in or out, and crossfades its tail into its head.
  private static let trimSeconds = 0.08
  private static let crossfadeSeconds = 0.3
  /// Stable Audio ends a clip in silence, about a quarter second after two
  /// seconds of sound and most of a second after eleven. The loop runs from
  /// the first sample louder than this to the last, so that padding is
  /// never heard as a gap.
  private static let silenceLevel: Float = 0.001

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
      if let voice = voices[key], voice.source != update.source {
        remove(voice)
        voices[key] = nil
      }
      if voices[key] == nil {
        // A silent voice need not start until it becomes audible.
        guard update.gain > 0 else { continue }
        voices[key] = switch update.source {
        case .sound(let url): try start(url)
        case .synth(let synth): try start(synth, slot: update.slot)
        }
      }
      voices[key]?.update(update)
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
    let player = AVAudioPlayerNode()
    let varispeed = AVAudioUnitVarispeed()
    let mixer = AVAudioMixerNode()
    engine.attach(player)
    engine.attach(varispeed)
    engine.attach(mixer)
    // Volume and pan apply where a node joins a mixer, so each voice has a
    // submixer directly on the main mixer behind its rate change.
    engine.connect(player, to: varispeed, format: loop.format)
    engine.connect(varispeed, to: mixer, format: loop.format)
    engine.connect(mixer, to: engine.mainMixerNode, format: loop.format)
    mixer.volume = 0
    try startEngine()
    player.scheduleBuffer(loop, at: nil, options: .loops)
    player.play()
    return Voice(source: .sound(url), nodes: [player, varispeed, mixer]) { update in
      mixer.volume = update.gain
      mixer.pan = update.pan
      varispeed.rate = update.rate
    }
  }

  /// A synthesized voice eases its own gain, pitch and pan sample by sample,
  /// so the program's frame-rate steps are never heard.
  private func start(_ synth: PipelineGPUAudioSynth, slot: Int) throws -> Voice {
    let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    guard sampleRate > 0,
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
    else { throw CocoaError(.featureUnsupported) }
    let controls = SynthControls()
    let node = Self.synthNode(synth, slot: slot, format: format, controls: controls)
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    try startEngine()
    return Voice(source: .synth(synth), nodes: [node]) { update in
      controls.set(.init(gain: update.gain, rate: update.rate, pan: update.pan,
        drive: update.drive))
    }
  }

  /// Built outside the main actor: the render block runs on the audio thread.
  private nonisolated static func synthNode(_ synth: PipelineGPUAudioSynth,
    slot: Int, format: AVAudioFormat, controls: SynthControls) -> AVAudioSourceNode {
    let renderer = SynthRenderer(PipelineRotorSynth(rotors: synth.rotors,
      blades: synth.blades, hz: synth.hz, sampleRate: format.sampleRate,
      seed: UInt32(slot + 1)))
    return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
      let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
      guard buffers.count >= 2,
        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
        let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
      else { return noErr }
      renderer.synth.render(controls.get(), left: left, right: right,
        frames: Int(frameCount))
      return noErr
    }
  }

  private func startEngine() throws {
    guard !engine.isRunning else { return }
    engine.prepare()
    try engine.start()
  }

  private func remove(_ voice: Voice) {
    for node in voice.nodes {
      (node as? AVAudioPlayerNode)?.stop()
      engine.detach(node)
    }
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
    guard let input = source.floatChannelData else { return nil }
    let channels = Int(source.format.channelCount)
    func audible(_ frame: Int) -> Bool {
      (0..<channels).contains { abs(input[$0][frame]) > silenceLevel }
    }
    var first = 0
    var end = Int(source.frameLength)
    while first < end, !audible(first) { first += 1 }
    while end > first, !audible(end - 1) { end -= 1 }
    let usable = end - first - 2 * trim
    let length = usable - fade
    guard fade > 0, length > 2 * fade,
      let loop = AVAudioPCMBuffer(pcmFormat: source.format,
        frameCapacity: AVAudioFrameCount(length)),
      let output = loop.floatChannelData else { return nil }
    loop.frameLength = AVAudioFrameCount(length)
    for channel in 0..<channels {
      let from = input[channel] + first + trim
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

/// The controls the main actor last set for a synthesized voice. The audio
/// thread reads them without locking.
private final class SynthControls: Sendable {
  private let gain = Atomic<UInt32>(0)
  private let rate = Atomic<UInt32>(Float(1).bitPattern)
  private let pan = Atomic<UInt32>(0)
  private let drive = Atomic<UInt32>(0)

  func set(_ controls: PipelineRotorSynth.Controls) {
    gain.store(controls.gain.bitPattern, ordering: .relaxed)
    rate.store(controls.rate.bitPattern, ordering: .relaxed)
    pan.store(controls.pan.bitPattern, ordering: .relaxed)
    drive.store(controls.drive.bitPattern, ordering: .relaxed)
  }

  func get() -> PipelineRotorSynth.Controls {
    .init(gain: Float(bitPattern: gain.load(ordering: .relaxed)),
      rate: Float(bitPattern: rate.load(ordering: .relaxed)),
      pan: Float(bitPattern: pan.load(ordering: .relaxed)),
      drive: Float(bitPattern: drive.load(ordering: .relaxed)))
  }
}

/// Owns a synthesizer that only the audio render thread touches.
private final class SynthRenderer: @unchecked Sendable {
  let synth: PipelineRotorSynth
  init(_ synth: PipelineRotorSynth) { self.synth = synth }
}
