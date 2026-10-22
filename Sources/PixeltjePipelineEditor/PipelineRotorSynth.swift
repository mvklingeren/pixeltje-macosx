import Foundation

/// The sound of an electric multirotor, synthesized sample by sample for a
/// GPU Program voice.
///
/// Each propeller is a phase accumulator turning at the rotor speed. A blade
/// passing a point in the air gives a pressure pulse, so a propeller's tone is
/// a harmonic series on the blade-pass frequency, read from a band-limited
/// wavetable; a slight imbalance between blades adds the shaft rate under it.
/// No two motors turn at exactly the same speed and the flight controller
/// trims each one many times a second, so every rotor carries its own small
/// detune and a slow random wander, and the rotors beat against each other
/// with the familiar swirl. The brushless motors add a quiet electrical
/// whine at their pole-pair multiple, and the blades chop turbulent air:
/// band-passed noise modulated at the blade rate, over a low wash.
///
/// Playback rate scales every frequency, rotor speed and Doppler shift alike.
/// Drive, 0–1, is how hard the motors work: it brightens the blade pulses,
/// raises whine and turbulence, and splits the motor speeds the way a tilted
/// drone runs one side faster than the other. Gain also darkens the sound, as
/// distance and walls take the highs first.
///
/// Only the audio render thread calls `render`.
final class PipelineRotorSynth {
  struct Controls: Equatable {
    var gain: Float
    var rate: Float
    var pan: Float
    var drive: Float
  }

  private static let tableSize = 2048
  /// Rotor speeds and filter coefficients update once per block.
  private static let blockFrames = 32
  /// A 14-pole outrunner motor: seven electrical cycles per revolution, and
  /// six commutation steps in each.
  private static let polePairs: Float = 7
  private static let commutation: Float = 42
  /// The playback rate the program may reach, for band-limiting.
  private static let maximumRate: Float = 4.2

  private let sampleRate: Float
  private let blades: Float
  private let hz: Float
  private let soft: [Float]
  private let hard: [Float]
  private let sine: [Float]
  private var rotors: [Rotor]
  private var random: UInt32
  private var smoothed: Controls?
  private var turbulence = SVF()
  private var washState: Float = 0
  private var airState: Float = 0

  private struct Rotor {
    var phase: Float
    /// Fixed fraction this motor runs off the nominal speed.
    let detune: Float
    /// Which side of the frame it sits on, -1 or 1.
    let side: Float
    var wander: Float = 0
    var wanderTarget: Float = 0
    var holdFrames = 0
    var step: Float = 0
  }

  /// Zero-delay-feedback state-variable filter; stable at any cutoff.
  private struct SVF {
    var ic1: Float = 0
    var ic2: Float = 0
    var a1: Float = 1
    var a2: Float = 0
    var a3: Float = 0
    var k: Float = 1

    mutating func tune(cutoff: Float, q: Float, sampleRate: Float) {
      let g = tan(Float.pi * min(cutoff, 0.45 * sampleRate) / sampleRate)
      k = 1 / q
      a1 = 1 / (1 + g * (g + k))
      a2 = g * a1
      a3 = g * a2
    }

    /// Band-pass output with unity gain at the centre.
    mutating func bandPass(_ input: Float) -> Float {
      let v3 = input - ic2
      let v1 = a1 * ic1 + a2 * v3
      let v2 = ic2 + a2 * ic1 + a3 * v3
      ic1 = 2 * v1 - ic1
      ic2 = 2 * v2 - ic2
      return k * v1
    }
  }

  /// - Parameters:
  ///   - hz: Propeller revolutions per second at playback rate 1.
  ///   - seed: Distinguishes voices so that drones never sound identical.
  init(rotors rotorCount: Int, blades: Int, hz: Float, sampleRate: Double,
    seed: UInt32) {
    self.sampleRate = Float(sampleRate)
    self.blades = Float(blades)
    self.hz = hz
    random = seed &* 747_796_405 &+ 2_891_336_453
    if random == 0 { random = 1 }
    // Keep the highest blade harmonic below Nyquist at the fastest rate.
    let bladePass = Float(blades) * hz * Self.maximumRate
    let harmonics = max(1, min(32, Int(0.42 * Float(sampleRate) / bladePass)))
    soft = Self.table(harmonics: harmonics) { n in pow(n, -1.2) }
    hard = Self.table(harmonics: harmonics) { n in
      pow(n, -0.85) * (1 + 0.8 * exp(-(n - 3) * (n - 3) / 3))
    }
    sine = Self.table(harmonics: 1) { _ in 1 }
    var rotors: [Rotor] = []
    for index in 0..<rotorCount {
      let spread = Float(index) / Float(max(rotorCount - 1, 1)) - 0.5
      rotors.append(Rotor(phase: 0,
        detune: 0.022 * spread,
        side: index % 2 == 0 ? -1 : 1))
    }
    self.rotors = rotors
    for index in rotors.indices {
      self.rotors[index].phase = nextUniform()
    }
  }

  /// Writes `frames` stereo samples of the voice, easing from the last
  /// controls toward `target`.
  func render(_ target: Controls, left: UnsafeMutablePointer<Float>,
    right: UnsafeMutablePointer<Float>, frames: Int) {
    // A voice coming out of silence takes its pitch at once and fades in.
    var controls = smoothed
      ?? Controls(gain: 0, rate: target.rate, pan: target.pan, drive: target.drive)
    let ease = 1 - exp(-Float(Self.blockFrames) / (0.035 * sampleRate))
    let tableSize = Float(Self.tableSize)
    let nyquist = 0.45 * sampleRate
    var start = 0
    while start < frames {
      let count = min(Self.blockFrames, frames - start)
      let previousGain = controls.gain
      let previousPan = controls.pan
      controls.gain += (target.gain - controls.gain) * ease
      controls.rate += (target.rate - controls.rate) * ease
      controls.pan += (target.pan - controls.pan) * ease
      controls.drive += (target.drive - controls.drive) * ease
      let drive = controls.drive
      let speed = hz * controls.rate
      updateRotors(speed: speed, drive: drive, frames: count)
      turbulence.tune(cutoff: 1_700 * controls.rate * (0.75 + 0.6 * drive),
        q: 0.9, sampleRate: sampleRate)
      let wash = 1 - exp(-2 * Float.pi * 260 * controls.rate / sampleRate)
      let distance = min(controls.gain / 0.85, 1).squareRoot()
      let air = 1 - exp(-2 * Float.pi * (1_400 + 16_000 * distance) / sampleRate)
      let whineLevel: Float = speed * Self.polePairs < nyquist ? 0.035 + 0.05 * drive : 0
      let stepLevel: Float = speed * Self.commutation < nyquist ? 0.01 + 0.02 * drive : 0
      let turbulenceLevel = 0.28 + 0.3 * drive
      let rotorScale = 1 / Float(rotors.count)
      for frame in 0..<count {
        let along = Float(frame + 1) / Float(count)
        var tone: Float = 0
        var shaft: Float = 0
        var whine: Float = 0
        var chop: Float = 0
        for index in rotors.indices {
          var phase = rotors[index].phase + rotors[index].step
          phase -= phase.rounded(.down)
          rotors[index].phase = phase
          var blade = phase * blades
          blade -= blade.rounded(.down)
          let pulse = Self.lookup(soft, blade, tableSize)
          tone += pulse + (Self.lookup(hard, blade, tableSize) - pulse) * drive
          shaft += Self.lookup(sine, phase, tableSize)
          var electrical = phase * Self.polePairs
          electrical -= electrical.rounded(.down)
          var commutation = phase * Self.commutation
          commutation -= commutation.rounded(.down)
          whine += whineLevel * Self.lookup(sine, electrical, tableSize)
            + stepLevel * Self.lookup(sine, commutation, tableSize)
          chop += Self.lookup(sine, blade, tableSize)
        }
        let noise = nextUniform() * 2 - 1
        washState += (noise - washState) * wash
        let turbulent = turbulence.bandPass(noise)
          * (1 + 0.6 * chop * rotorScale)
        var mono = 0.8 * tone * rotorScale + 0.1 * shaft * rotorScale
          + whine * rotorScale + turbulenceLevel * turbulent + 0.7 * washState
        airState += (mono - airState) * air
        mono = airState
        let gain = previousGain + (controls.gain - previousGain) * along
        let pan = previousPan + (controls.pan - previousPan) * along
        let angle = (pan + 1) * (Float.pi / 4)
        let level = 0.75 * gain * mono
        left[start + frame] = level * cos(angle)
        right[start + frame] = level * sin(angle)
      }
      start += count
    }
    smoothed = controls
  }

  /// Rotor speeds for the next block. A working drone holds its motors less
  /// evenly: the wander grows with drive, and the two sides split apart.
  private func updateRotors(speed: Float, drive: Float, frames: Int) {
    let ease = 1 - exp(-Float(frames) / (0.12 * sampleRate))
    let wanderDepth = 0.004 + 0.012 * drive
    let split = 0.03 * drive * drive
    for index in rotors.indices {
      rotors[index].holdFrames -= frames
      if rotors[index].holdFrames <= 0 {
        rotors[index].wanderTarget = nextUniform() * 2 - 1
        rotors[index].holdFrames = Int((0.08 + 0.3 * nextUniform()) * sampleRate)
      }
      rotors[index].wander += (rotors[index].wanderTarget - rotors[index].wander) * ease
      let rotor = rotors[index]
      let factor = 1 + rotor.detune + rotor.side * split + rotor.wander * wanderDepth
      rotors[index].step = speed * factor / sampleRate
    }
  }

  private func nextUniform() -> Float {
    random ^= random << 13
    random ^= random >> 17
    random ^= random << 5
    return Float(random >> 8) / Float(1 << 24)
  }

  private static func lookup(_ table: [Float], _ phase: Float, _ size: Float) -> Float {
    let position = phase * size
    let index = Int(position)
    let fraction = position - Float(index)
    return table[index] + (table[index + 1] - table[index]) * fraction
  }

  /// One period of a harmonic series with the given amplitudes, normalized
  /// to a peak of 1, with a guard sample so lookups need no wrap. Spread
  /// phases keep the pulse from being needle-sharp.
  private static func table(harmonics: Int, amplitude: (Float) -> Float) -> [Float] {
    var values = [Float](repeating: 0, count: tableSize + 1)
    for index in 0..<tableSize {
      let x = Float(index) / Float(tableSize)
      var sum: Float = 0
      for harmonic in 1...harmonics {
        let n = Float(harmonic)
        let offset = harmonic == 1 ? 0 : 0.9 * n * n
        sum += amplitude(n) * sin(2 * Float.pi * n * x + offset)
      }
      values[index] = sum
    }
    let peak = values.map(abs).max() ?? 1
    if peak > 0 { values = values.map { $0 / peak } }
    values[tableSize] = values[0]
    return values
  }
}
