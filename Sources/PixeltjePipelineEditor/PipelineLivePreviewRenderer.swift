import CoreGraphics
import Foundation
import IOSurface
import Metal
import PixeltjePipelineEngine
import QuartzCore
import Synchronization

/// A run loop away from the main thread for live preview display links, so a
/// busy main thread cannot delay presentation.
final class PipelineLivePreviewRenderThread: @unchecked Sendable {
  static let shared = PipelineLivePreviewRenderThread()

  private let runLoop: CFRunLoop

  private init() {
    final class Handoff: @unchecked Sendable { var runLoop: CFRunLoop? }
    let handoff = Handoff()
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread {
      handoff.runLoop = CFRunLoopGetCurrent()
      // A port keeps the run loop alive while no display link is scheduled.
      RunLoop.current.add(NSMachPort(), forMode: .default)
      ready.signal()
      while true {
        _ = RunLoop.current.run(mode: .default, before: .distantFuture)
      }
    }
    thread.name = "Pixeltje live preview"
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    runLoop = handoff.runLoop!
  }

  /// Runs `body` on the render thread.
  func perform(_ body: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, body)
    CFRunLoopWakeUp(runLoop)
  }
}

/// The device, queue and pipeline shared by every preview view.
final class PipelineLivePreviewPresentation: @unchecked Sendable {
  static let shared = PipelineLivePreviewPresentation()

  let device: (any MTLDevice)?
  let commandQueue: (any MTLCommandQueue)?
  let pipeline: (any MTLRenderPipelineState)?

  private init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
    commandQueue = device?.makeCommandQueue()
    pipeline = device.flatMap { device in
      guard let library = try? device.makeLibrary(source: Self.shader, options: nil),
        let vertex = library.makeFunction(name: "previewVertex"),
        let fragment = library.makeFunction(name: "previewFragment") else { return nil }
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
  }

  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct PreviewVertex { float4 position [[position]]; float2 uv; };
    vertex PreviewVertex previewVertex(uint id [[vertex_id]]) {
      const float2 positions[4] = {float2(-1, 1), float2(1, 1),
        float2(-1, -1), float2(1, -1)};
      const float2 coordinates[4] = {float2(0, 0), float2(1, 0),
        float2(0, 1), float2(1, 1)};
      PreviewVertex output;
      output.position = float4(positions[id], 0, 1);
      output.uv = coordinates[id];
      return output;
    }
    fragment float4 previewFragment(PreviewVertex input [[stage_in]],
      texture2d<half> source [[texture(0)]]) {
      constexpr sampler sampleFilter(filter::linear);
      half4 value = source.sample(sampleFilter, input.uv);
      return float4(float3(value.rgb * value.a), 1);
    }
    """
}

/// The completion handler only retains these; it never reads or mutates them.
private final class PipelinePreviewTextureLease: @unchecked Sendable {
  let frame: PipelineMetalPreviewFrame?
  let texture: (any MTLTexture)?

  init(frame: PipelineMetalPreviewFrame?, texture: (any MTLTexture)?) {
    self.frame = frame
    self.texture = texture
  }
}

/// Draws one preview view's Metal layer from a display link on the render
/// thread. The main actor only changes its settings; every layer, link and
/// drawing call happens on the render thread.
final class PipelineLivePreviewLayerRenderer: NSObject, CAMetalDisplayLinkDelegate,
  @unchecked Sendable {
  private struct Settings: Sendable {
    var source: PipelineLivePreviewSource?
    var drawableSize = CGSize.zero
    var isVisible = false
    var isPacing = false
    var isStopped = false
  }

  private let settings = Mutex(Settings())
  private let layer: CAMetalLayer
  private let viewID = UUID()
  private let renderThread = PipelineLivePreviewRenderThread.shared
  private let presentation = PipelineLivePreviewPresentation.shared

  // Render-thread state.
  private var link: CAMetalDisplayLink?
  private var source: PipelineLivePreviewSource?
  private var frame: PipelineMetalPreviewFrame?
  private var revision: UInt64 = 0
  private var drawableSize = CGSize.zero
  private var isVisible = false
  private var isPacing = false
  private var isStopped = false
  private var needsDraw = true
  private var lastPresentationTimestamp: CFTimeInterval?
  private var refreshInterval: CFTimeInterval?

  init(layer: CAMetalLayer) {
    self.layer = layer
    super.init()
    layer.device = presentation.device
    layer.pixelFormat = .bgra8Unorm
    layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    layer.framebufferOnly = true
    layer.maximumDrawableCount = 3
    layer.isOpaque = true
    layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    // A resize shows the previous drawable at its aspect ratio until the
    // render thread draws at the new size.
    layer.contentsGravity = .resizeAspect
  }

  func setSource(_ source: PipelineLivePreviewSource?) {
    change { $0.source = source }
  }

  func setDrawableSize(_ size: CGSize) {
    change { $0.drawableSize = size }
  }

  func setVisible(_ visible: Bool) {
    change { $0.isVisible = visible }
  }

  /// A pacing view publishes its refresh timing to the run.
  func setPacing(_ pacing: Bool) {
    change { $0.isPacing = pacing }
  }

  /// Lets the link draw a finished run's last frame and then idle.
  func sourceDidFinish() {
    renderThread.perform { [self] in
      needsDraw = true
      apply()
    }
  }

  /// Invalidates the display link. The renderer cannot be restarted.
  func stop() {
    change { $0.isStopped = true }
  }

  private func change(_ body: (inout Settings) -> Void) {
    settings.withLock { body(&$0) }
    renderThread.perform { [self] in apply() }
  }

  /// Render thread: applies the latest settings to the link and layer.
  private func apply() {
    guard !isStopped else { return }
    let latest = settings.withLock { $0 }
    if latest.isStopped {
      isStopped = true
      link?.invalidate()
      link = nil
      source = nil
      frame = nil
      return
    }
    if latest.source !== source {
      source = latest.source
      revision = 0
      frame = nil
      needsDraw = true
    }
    if latest.drawableSize != drawableSize {
      drawableSize = latest.drawableSize
      if hasDrawableSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.drawableSize = drawableSize
        CATransaction.commit()
      }
      needsDraw = true
    }
    isVisible = latest.isVisible
    if isPacing != latest.isPacing {
      isPacing = latest.isPacing
      lastPresentationTimestamp = nil
    }
    if link == nil, isVisible {
      let link = CAMetalDisplayLink(metalLayer: layer)
      link.delegate = self
      link.preferredFrameLatency = 1
      link.add(to: .current, forMode: .default)
      self.link = link
    }
    // A GPU Program's frames change only at its Loop rate, so its views
    // refresh at that rate; shader-state previews interpolate per refresh.
    if let link, let rate = source?.isActive == true ? source?.preferredFramesPerSecond : nil {
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
    } else {
      link?.preferredFrameRateRange = .default
    }
    updatePause()
  }

  private var hasDrawableSize: Bool {
    drawableSize.width > 0 && drawableSize.height > 0
  }

  private func updatePause() {
    let runs = isVisible && hasDrawableSize && (needsDraw || source?.isActive == true)
    if link?.isPaused != !runs { link?.isPaused = !runs }
  }

  func metalDisplayLink(_ link: CAMetalDisplayLink,
    needsUpdate update: CAMetalDisplayLink.Update) {
    guard !isStopped else { return }
    if isPacing, let source, source.isActive {
      publishRefresh(update, to: source)
    }
    var presented: PipelineLiveFrameMailbox.Entry?
    if let source, let newest = source.frames.frame(after: revision) {
      revision = newest.revision
      frame = newest.frame
      presented = newest
      needsDraw = true
    }
    if needsDraw {
      needsDraw = false
      draw(into: update.drawable, presenting: presented)
    }
    updatePause()
  }

  private func publishRefresh(_ update: CAMetalDisplayLink.Update,
    to source: PipelineLivePreviewSource) {
    let target = update.targetPresentationTimestamp
    if let previous = lastPresentationTimestamp {
      let delta = target - previous
      if delta > 0, delta < 0.25 {
        refreshInterval = refreshInterval.map { $0 * 0.9 + delta * 0.1 } ?? delta
      }
    }
    lastPresentationTimestamp = target
    let interval = refreshInterval
      ?? 1 / Double(source.preferredFramesPerSecond ?? 60)
    source.refresh.tick(.init(timestamp: CACurrentMediaTime(), interval: interval))
  }

  private func draw(into drawable: any CAMetalDrawable,
    presenting presented: PipelineLiveFrameMailbox.Entry?) {
    guard let device = presentation.device,
      let pipeline = presentation.pipeline,
      let commandBuffer = presentation.commandQueue?.makeCommandBuffer() else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
    var texture: (any MTLTexture)?
    if let frame {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: frame.width, height: frame.height,
        mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = .shaderRead
      texture = device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0)
    }
    if let frame, let texture {
      let width = CGFloat(drawable.texture.width)
      let height = CGFloat(drawable.texture.height)
      let scale = min(width / CGFloat(frame.width), height / CGFloat(frame.height))
      let fittedWidth = CGFloat(frame.width) * scale
      let fittedHeight = CGFloat(frame.height) * scale
      encoder.setViewport(MTLViewport(
        originX: (width - fittedWidth) / 2, originY: (height - fittedHeight) / 2,
        width: fittedWidth, height: fittedHeight, znear: 0, zfar: 1))
      encoder.setRenderPipelineState(pipeline)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    encoder.endEncoding()
    // The surface stays leased until this GPU sampling command finishes, even
    // if a newer frame replaces it meanwhile.
    let lease = PipelinePreviewTextureLease(frame: frame, texture: texture)
    commandBuffer.addCompletedHandler { _ in _ = lease }
    let log = presented.flatMap { _ in source?.performanceLog }
    if let presented, let log {
      let event = displayEvent(for: presented)
      drawable.addPresentedHandler { _ in
        let now = DispatchTime.now().uptimeNanoseconds
        Task { await log.recordDisplay(event("displayPresented", now)) }
      }
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    if let presented {
      if let log {
        let event = displayEvent(for: presented)
        let now = DispatchTime.now().uptimeNanoseconds
        Task { await log.recordDisplay(event("displaySubmitted", now)) }
      }
    }
  }

  private func displayEvent(for entry: PipelineLiveFrameMailbox.Entry)
    -> @Sendable (String, UInt64) -> PipelineEditorPerformanceLog.Display {
    let runID = entry.frame.runID
    let viewID = viewID
    let surfaceID = IOSurfaceGetID(entry.frame.surface)
    let publishedAt = entry.publishedAt
    return { event, now in
      .init(event: event, runID: runID, viewID: viewID, surfaceID: surfaceID,
        uptimeSeconds: Double(now) / 1_000_000_000,
        latencySeconds: Double(now &- publishedAt) / 1_000_000_000)
    }
  }
}
