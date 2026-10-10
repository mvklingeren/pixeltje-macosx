import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PixeltjePipelineEngine

/// Writes one completed pipeline frame at a time. Appending applies encoder
/// backpressure; no earlier full-size frames are retained by this writer.
public actor PipelineStreamingVideoWriter {
  private let outputURL: URL
  private let framesPerSecond: Double
  private var writer: AVAssetWriter?
  private var receiver: AVAssetWriterInput.PixelBufferReceiver?
  private var width = 0
  private var height = 0
  private var frameCount = 0
  private var semanticSHA256 = ""
  private var finished = false

  public init(outputURL: URL, framesPerSecond: Double) throws {
    guard framesPerSecond.isFinite, framesPerSecond > 0,
      framesPerSecond <= 240 else {
      throw PipelineStreamingVideoError.invalidFrameRate
    }
    self.outputURL = outputURL
    self.framesPerSecond = framesPerSecond
  }

  public func append(_ frame: PipelineVideoFrame) async throws {
    try Task.checkCancellation()
    guard !finished, frame.framesPerSecond == framesPerSecond else {
      throw PipelineStreamingVideoError.changedSettings
    }
    let image = frame.image
    if writer == nil { try start(with: image) }
    guard image.width == width, image.height == height,
      image.semanticPipelineSHA256 == semanticSHA256,
      let receiver else {
      throw PipelineStreamingVideoError.changedSettings
    }
    let buffer = try Self.pixelBuffer(from: image)
    let time = CMTime(seconds: Double(frameCount) / framesPerSecond,
      preferredTimescale: 60_000)
    try await receiver.append(buffer, with: time)
    frameCount += 1
  }

  public func finish() async throws -> PipelineGeneratedVideo {
    try Task.checkCancellation()
    guard !finished, frameCount > 0, let writer, let receiver else {
      throw PipelineStreamingVideoError.noFrames
    }
    finished = true
    receiver.finish()
    writer.endSession(atSourceTime: CMTime(
      seconds: Double(frameCount) / framesPerSecond, preferredTimescale: 60_000))
    await writer.finishWriting()
    guard writer.status == .completed else {
      let reason = writer.error?.localizedDescription ?? "unknown encoder error"
      cancel()
      throw PipelineStreamingVideoError.writeFailed(reason)
    }
    self.writer = nil
    self.receiver = nil
    return PipelineGeneratedVideo(fileURL: outputURL, width: width, height: height,
      frameCount: frameCount, framesPerSecond: framesPerSecond,
      semanticPipelineSHA256: semanticSHA256)
  }

  public func cancel() {
    finished = true
    writer?.cancelWriting()
    writer = nil
    receiver = nil
    try? FileManager.default.removeItem(at: outputURL)
  }

  private func start(with image: PipelineGeneratedImage) throws {
    guard image.width > 0, image.height > 0,
      image.width.isMultiple(of: 2), image.height.isMultiple(of: 2) else {
      throw PipelineStreamingVideoError.oddDimensions
    }
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let bitRate = Int(min(80_000_000,
      max(2_000_000, Double(image.width) * Double(image.height)
        * framesPerSecond * 0.08)).rounded())
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: image.width,
      AVVideoHeightKey: image.height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw PipelineStreamingVideoError.writeFailed(
        "H.264 MP4 encoding is unavailable for this frame size on this Mac")
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let receiver = writer.inputPixelBufferReceiver(for: input,
      pixelBufferAttributes: nil)
    try writer.start()
    writer.startSession(atSourceTime: .zero)
    self.writer = writer
    self.receiver = receiver
    width = image.width
    height = image.height
    semanticSHA256 = image.semanticPipelineSHA256
  }

  private static func pixelBuffer(
    from image: PipelineGeneratedImage
  ) throws -> CVReadOnlyPixelBuffer {
    let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
    guard !overflow, pixels > 0, pixels <= Int.max / 3,
      image.planarRGB.count == pixels * 3,
      image.alpha.map({ $0.count == pixels }) ?? true else {
      throw PipelineStreamingVideoError.invalidFrame
    }
    var optionalBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
      kCVPixelFormatType_32ARGB, attributes as CFDictionary,
      &optionalBuffer) == kCVReturnSuccess,
      let buffer = optionalBuffer else {
      throw PipelineStreamingVideoError.writeFailed("Could not allocate a video frame buffer")
    }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
      throw PipelineStreamingVideoError.writeFailed("Could not access the video frame buffer")
    }
    do {
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
        throw PipelineStreamingVideoError.writeFailed("Video frame buffer has no pixel storage")
      }
      let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
      for y in 0..<image.height {
        try Task.checkCancellation()
        for x in 0..<image.width {
          let index = y * image.width + x
          let alpha = image.alpha?[index] ?? 1
          guard alpha.isFinite, (0...1).contains(alpha) else {
            throw PipelineStreamingVideoError.invalidFrame
          }
          let offset = y * rowBytes + x * 4
          base[offset] = 255
          for channel in 0..<3 {
            let component = image.encoding.normalizedSRGBComponent(
              from: image.planarRGB[channel * pixels + index])
            guard component.isFinite else { throw PipelineStreamingVideoError.invalidFrame }
            // H.264 has no alpha plane. Composite transparent pixels over black.
            base[offset + channel + 1] = UInt8((min(1, max(0, component))
              * alpha * 255).rounded())
          }
        }
      }
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw PipelineStreamingVideoError.writeFailed("sRGB color space is unavailable")
    }
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
      colorSpace, .shouldPropagate)
    return CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
  }
}

public enum PipelineStreamingVideoError: LocalizedError, Sendable {
  case invalidFrameRate
  case oddDimensions
  case invalidFrame
  case changedSettings
  case noFrames
  case writeFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidFrameRate: "Video frame rate must be greater than 0 and at most 240."
    case .oddDimensions: "H.264 video requires positive, even frame dimensions."
    case .invalidFrame: "The video frame contains invalid image data."
    case .changedSettings: "Video frame dimensions, frame rate or pipeline changed during recording."
    case .noFrames: "Video recording produced no frames."
    case .writeFailed(let reason): "Could not write video: \(reason)."
    }
  }
}
