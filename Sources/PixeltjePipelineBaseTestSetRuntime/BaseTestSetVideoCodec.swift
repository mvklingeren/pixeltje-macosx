import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// The model-free fixture's bounded H.264/AAC media path. Video frames enter
/// the graph as display-referred sRGB; compressed AAC is copied unchanged.
enum BaseTestSetCodec {
  static func openVideo(at url: URL) async throws -> BaseTestSetVideo {
    try await BaseTestSetVideoFrameDecoder.shared.openVideo(at: url)
  }

  static func frame(_ index: Int, from video: BaseTestSetVideo) async throws -> BaseTestSetImage {
    guard (0..<video.frameCount).contains(index) else {
      throw BaseTestSetError.invalid("Video frame \(index) is outside 0–\(video.frameCount - 1).")
    }
    if let sourceURL = video.sourceURL {
      return try await BaseTestSetVideoFrameDecoder.shared.frame(
        at: index, from: sourceURL, framesPerSecond: video.framesPerSecond)
    }
    return video.frames[index]
  }

  static func decodeVideo(at url: URL) async throws -> BaseTestSetVideo {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw BaseTestSetError.invalid("Video \(url.lastPathComponent) has no video track.")
    }
    let frameRate = Double(try await track.load(.nominalFrameRate))
    let transform = try await track.load(.preferredTransform)
    guard frameRate.isFinite, frameRate > 0, transform.isIdentity else {
      throw BaseTestSetError.invalid("Video needs a positive frame rate and upright frames.")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
    ])
    let provider = reader.outputProvider(for: output)
    try reader.start()
    defer { if reader.status == .reading { reader.cancelReading() } }

    var frames: [BaseTestSetImage] = []
    while let sample = try await provider.next() {
      try Task.checkCancellation()
      guard frames.count < 48 else {
        throw BaseTestSetError.invalid("Video exceeds the 512-pixel or 48-frame fixture limit.")
      }
      let frame = try sample.withUnsafeSampleBuffer { unsafeSample in
        guard let buffer = CMSampleBufferGetImageBuffer(unsafeSample) else {
          throw BaseTestSetError.invalid("Decoded video sample has no image buffer.")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width <= 512, height <= 512 else {
          throw BaseTestSetError.invalid("Video exceeds the 512-pixel fixture limit.")
        }
        return try NativeImageColor.image(from: CIImage(cvPixelBuffer: buffer),
          width: width, height: height)
      }
      frames.append(frame)
    }
    guard reader.status == .completed, !frames.isEmpty else {
      throw BaseTestSetError.invalid("Could not decode video frames: \(reader.error?.localizedDescription ?? "no frames").")
    }
    let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
    return BaseTestSetVideo(frames: frames, audioSource: hasAudio ? url : nil,
      framesPerSecond: frameRate)
  }

  static func encodeVideo(_ video: BaseTestSetVideo, to url: URL) async throws {
    guard let first = video.frames.first, video.framesPerSecond.isFinite,
      video.framesPerSecond > 0, video.framesPerSecond <= 240,
      first.width.isMultiple(of: 2), first.height.isMultiple(of: 2),
      video.frames.allSatisfy({ $0.width == first.width && $0.height == first.height })
    else {
      throw BaseTestSetError.invalid("H.264 needs nonempty, even-sized frames and a valid frame rate.")
    }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: first.width,
      AVVideoHeightKey: first.height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw BaseTestSetError.invalid("H.264 encoding is unavailable on this Mac.")
    }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let videoReceiver = writer.inputPixelBufferReceiver(for: videoInput,
      pixelBufferAttributes: nil)
    let audio: AudioTransfer?
    if let audioSource = video.audioSource {
      audio = try await audioTransfer(from: audioSource, writer: writer)
    } else {
      audio = nil
    }
    let duration = CMTime(seconds: Double(video.frames.count) / video.framesPerSecond,
      preferredTimescale: 60_000)

    do {
      try writer.start()
      writer.startSession(atSourceTime: .zero)
      if let audio { try audio.reader.start() }
      async let audioWork: Void = copyAudio(audio, until: duration)
      for (index, frame) in video.frames.enumerated() {
        try Task.checkCancellation()
        let buffer = try pixelBuffer(for: frame)
        let time = CMTime(seconds: Double(index) / video.framesPerSecond,
          preferredTimescale: 60_000)
        try await videoReceiver.append(buffer, with: time)
      }
      videoReceiver.finish()
      try await audioWork
      writer.endSession(atSourceTime: duration)
      await writer.finishWriting()
      guard writer.status == .completed else {
        throw BaseTestSetError.invalid("Could not finish H.264 video: \(writer.error?.localizedDescription ?? "unknown error").")
      }
    } catch {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  // The reader/provider are used only by copyAudio after start(); the writer
  // receiver is designed for concurrent audio and video appends.
  private struct AudioTransfer: @unchecked Sendable {
    let reader: AVAssetReader
    let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    let receiver: AVAssetWriterInput.SampleBufferReceiver
  }

  private static func audioTransfer(from url: URL, writer: AVAssetWriter) async throws -> AudioTransfer {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first,
      let format = try await track.load(.formatDescriptions).first,
      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format),
      stream.pointee.mFormatID == kAudioFormatMPEG4AAC
    else {
      throw BaseTestSetError.invalid("Video audio passthrough requires an AAC track.")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    let provider = reader.outputProvider(for: output)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
      sourceFormatHint: format)
    let receiver = writer.inputReceiver(for: input)
    return AudioTransfer(reader: reader, provider: provider, receiver: receiver)
  }

  private static func copyAudio(_ transfer: AudioTransfer?, until duration: CMTime) async throws {
    guard let transfer else { return }
    while let sample = try await transfer.provider.next() {
      try Task.checkCancellation()
      let time = sample.presentationTimeStamp
      if time < .zero { continue } // AAC encoder priming precedes the first video frame.
      if time >= duration { break }
      try await transfer.receiver.append(sample)
    }
    transfer.receiver.finish()
    guard transfer.reader.status == .completed || transfer.reader.status == .reading else {
      throw BaseTestSetError.invalid("Could not copy AAC: \(transfer.reader.error?.localizedDescription ?? "unknown error").")
    }
    if transfer.reader.status == .reading { transfer.reader.cancelReading() }
  }

  private static func pixelBuffer(for frame: BaseTestSetImage) throws -> CVReadOnlyPixelBuffer {
    let bytes = try NativeImageColor.sRGBBytes(frame)
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    var maybeBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height,
      kCVPixelFormatType_32ARGB, attributes as CFDictionary, &maybeBuffer) == kCVReturnSuccess,
      let buffer = maybeBuffer else {
      throw BaseTestSetError.invalid("Could not allocate a video frame buffer.")
    }
    do {
      guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw BaseTestSetError.invalid("Could not access a video frame buffer.")
      }
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
        throw BaseTestSetError.invalid("Video frame buffer has no pixel storage.")
      }
      let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
      for y in 0..<frame.height {
        for x in 0..<frame.width {
          let source = (y * frame.width + x) * 4
          let target = y * rowBytes + x * 4
          base[target] = bytes[source + 3]
          base[target + 1] = bytes[source]
          base[target + 2] = bytes[source + 1]
          base[target + 3] = bytes[source + 2]
        }
      }
    }
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw BaseTestSetError.invalid("sRGB is unavailable for video output.")
    }
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
    return CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
  }
}

/// Keeps a sequential reader and source metadata across Loop calls without
/// retaining earlier full-size frames. Scrubbing uses exact-time extraction.
private actor BaseTestSetVideoFrameDecoder {
  static let shared = BaseTestSetVideoFrameDecoder()
  private typealias VideoSample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

  private struct CachedSource {
    let url: URL
    let resolvedURL: URL
    let fileSize: Int64
    let modificationDate: Date
    let fileNumber: UInt64?
    let asset: AVURLAsset
    let track: AVAssetTrack
    let video: BaseTestSetVideo
  }

  private struct Stream {
    let sourceURL: URL
    let framesPerSecond: Double
    let reader: AVAssetReader
    let provider: AVAssetReaderOutput.Provider<VideoSample>
    var nextIndex: Int
  }

  private var cachedSource: CachedSource?
  private var stream: Stream?
  private var streamBusy = false
  private var sourceURL: URL?
  private var generator: AVAssetImageGenerator?

  func openVideo(at url: URL) async throws -> BaseTestSetVideo {
    try await loadedSource(for: url).video
  }

  private func loadedSource(for url: URL) async throws -> CachedSource {
    let resolvedURL = url.resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
    guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
      let modificationDate = attributes[.modificationDate] as? Date else {
      throw BaseTestSetError.invalid("Could not read video file metadata.")
    }
    let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    if let cachedSource, cachedSource.url == url,
      cachedSource.resolvedURL == resolvedURL,
      cachedSource.fileSize == fileSize,
      cachedSource.modificationDate == modificationDate,
      cachedSource.fileNumber == fileNumber {
      return cachedSource
    }
    if cachedSource?.url == url {
      stopStream()
      sourceURL = nil
      generator = nil
    }
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw BaseTestSetError.invalid("Video \(url.lastPathComponent) has no video track.")
    }
    let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
    let minimumFrameDuration = try await track.load(.minFrameDuration).seconds
    let measuredFrameRate = 1 / minimumFrameDuration
    // Some constant-rate files report a slightly inaccurate nominal rate.
    // Even a small error accumulates enough to reject sequential samples
    // halfway through a clip, forcing an exact-time seek for every later frame.
    let frameRate = measuredFrameRate.isFinite && measuredFrameRate > 0
      && nominalFrameRate.isFinite && nominalFrameRate > 0
      && abs(measuredFrameRate - nominalFrameRate) / nominalFrameRate <= 0.01
      ? measuredFrameRate : nominalFrameRate
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let duration = try await track.load(.timeRange).duration.seconds
    guard frameRate.isFinite, frameRate > 0, frameRate <= 240,
      duration.isFinite, duration > 0, transform.isIdentity,
      size.width > 0, size.height > 0 else {
      throw BaseTestSetError.invalid("Video needs upright frames and a valid duration and frame rate.")
    }
    let frameCount = Int((duration * frameRate).rounded())
    guard frameCount > 0 else {
      throw BaseTestSetError.invalid("Video has no frames.")
    }
    let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
    let video = BaseTestSetVideo(sourceURL: url, frameCount: frameCount,
      width: Int(size.width), height: Int(size.height),
      framesPerSecond: frameRate, hasAudio: hasAudio)
    let source = CachedSource(url: url, resolvedURL: resolvedURL,
      fileSize: fileSize, modificationDate: modificationDate, fileNumber: fileNumber,
      asset: asset, track: track, video: video)
    cachedSource = source
    return source
  }

  func frame(at index: Int, from url: URL, framesPerSecond: Double) async throws -> BaseTestSetImage {
    if !streamBusy && (index == 0 || (stream?.sourceURL == url
      && stream?.framesPerSecond == framesPerSecond && stream?.nextIndex == index)) {
      streamBusy = true
      defer { streamBusy = false }
      return try await sequentialFrame(at: index, from: url, framesPerSecond: framesPerSecond)
    }
    return try await exactFrame(at: index, from: url, framesPerSecond: framesPerSecond)
  }

  private func sequentialFrame(
    at index: Int, from url: URL, framesPerSecond: Double
  ) async throws -> BaseTestSetImage {
    if index == 0 {
      try await startStream(from: url, framesPerSecond: framesPerSecond)
    }
    guard let stream else {
      throw BaseTestSetError.invalid("Could not start a video frame reader.")
    }
    do {
      guard let sample = try await stream.provider.next() else {
        throw BaseTestSetError.invalid("Could not decode video frame \(index): \(stream.reader.error?.localizedDescription ?? "end of video").")
      }
      try Task.checkCancellation()
      let expectedTime = Double(index) / framesPerSecond
      let actualTime = sample.presentationTimeStamp.seconds
      // A variable-rate or offset clip may not have one sample per nominal
      // frame interval. Preserve exact-frame behavior for those clips.
      guard actualTime.isFinite,
        abs(actualTime - expectedTime) <= 0.5 / framesPerSecond else {
        stopStream()
        return try await exactFrame(at: index, from: url, framesPerSecond: framesPerSecond)
      }
      let image = try sample.withUnsafeSampleBuffer { unsafeSample in
        guard let buffer = CMSampleBufferGetImageBuffer(unsafeSample) else {
          throw BaseTestSetError.invalid("Decoded video sample has no image buffer.")
        }
        return try NativeImageColor.image(from: CIImage(cvPixelBuffer: buffer),
          width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
      }
      self.stream?.nextIndex = index + 1
      return image
    } catch {
      stopStream()
      throw error
    }
  }

  private func startStream(from url: URL, framesPerSecond: Double) async throws {
    stopStream()
    let source = try await loadedSource(for: url)
    let reader = try AVAssetReader(asset: source.asset)
    let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    ])
    let provider = reader.outputProvider(for: output)
    try reader.start()
    stream = Stream(sourceURL: url, framesPerSecond: framesPerSecond,
      reader: reader, provider: provider, nextIndex: 0)
  }

  private func stopStream() {
    if stream?.reader.status == .reading { stream?.reader.cancelReading() }
    stream = nil
  }

  private func exactFrame(
    at index: Int, from url: URL, framesPerSecond: Double
  ) async throws -> BaseTestSetImage {
    if sourceURL != url {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      self.generator = generator
      sourceURL = url
    }
    guard let generator else {
      throw BaseTestSetError.invalid("Could not create a video frame reader.")
    }
    let time = CMTime(seconds: Double(index) / framesPerSecond,
      preferredTimescale: 60_000)
    let image: CGImage = try await withCheckedThrowingContinuation { continuation in
      generator.generateCGImageAsynchronously(for: time) { image, _, error in
        if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: error ?? BaseTestSetError.invalid(
            "Could not decode video frame \(index)."))
        }
      }
    }
    return try NativeImageColor.image(from: CIImage(cgImage: image),
      width: image.width, height: image.height)
  }
}
