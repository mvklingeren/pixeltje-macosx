import CoreImage
import CoreVideo
import Foundation
import IOSurface
import Metal
import PixeltjeMacDomain

/// A consumer-neutral request for either a color paint surface or a mask.
/// `cacheID` names the logical surface; callers use a layer id for committed
/// paint and a gesture id for provisional paint.
public struct StrokeSurfaceRequest: Sendable {
  public var cacheID: String
  public var recipe: StrokeSurfaceRecipe
  public var width: Int
  public var height: Int

  public init(cacheID: String, recipe: StrokeSurfaceRecipe, width: Int, height: Int) {
    self.cacheID = cacheID
    self.recipe = recipe
    self.width = width
    self.height = height
  }
}

public struct StrokeSurfaceTile: Sendable {
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int
  public let surface: IOSurface
}

public struct StrokeSurfaceFrame: Sendable {
  public let cacheID: String
  public let kind: StrokeSurfaceKind
  public let width: Int
  public let height: Int
  public let tiles: [StrokeSurfaceTile]
}

/// A dense readback used by deterministic pixel tests and small future mask
/// consumers. Normal display and composition stay tiled and never allocate it.
public struct StrokeSurfacePixels: Sendable {
  public let width: Int
  public let height: Int
  public let componentCount: Int
  public let values: [Float]

  public func value(x: Int, y: Int, component: Int = 0) -> Float? {
    guard (0..<width).contains(x), (0..<height).contains(y),
      (0..<componentCount).contains(component)
    else { return nil }
    return values[(y * width + x) * componentCount + component]
  }
}

/// Owns the Metal implementation behind `RenderEngine`.
///
/// This is deliberately not an actor of its own: every call is isolated by the
/// render actor, so its textures, command queue, pipeline state, and LRU remain
/// in the one rendering owner.
final class BrushMetalRenderer {
  static let tileSize = 256
  static let memoryBudget = 256 * 1_024 * 1_024

  private struct TileCoordinate: Hashable, Comparable {
    var x: Int
    var y: Int

    static func < (lhs: TileCoordinate, rhs: TileCoordinate) -> Bool {
      lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
  }

  private struct SurfaceKey: Hashable {
    var id: String
    var kind: StrokeSurfaceKind
    var width: Int
    var height: Int
  }

  private struct ClipSurfaceKey: Hashable {
    var recipe: Data
    var width: Int
    var height: Int
  }

  private struct ClipTileKey: Hashable {
    var surface: ClipSurfaceKey
    var coordinate: TileCoordinate
  }

  private struct CachedClipImage {
    var image: CIImage
    var lastAccess: UInt64
  }

  private struct Tile {
    var surface: IOSurface
    var texture: any MTLTexture
  }

  private struct CachedSurface {
    var recipe: StrokeSurfaceRecipe
    var tiles: [TileCoordinate: Tile]
    var lastAccess: UInt64
  }

  private struct StampParameters {
    /// Center in tile pixels and the brush-local x/y radii.
    var geometry: SIMD4<Float>
    /// Cosine, sine, hardness, tip shape (0 round, 1 ellipse, 2 rectangle).
    var appearance: SIMD4<Float>
    /// Grain amount, grain kind, deterministic seed, reserved.
    var texture: SIMD4<Float>
    /// Straight linear color.
    var color: SIMD4<Float>
    /// Opacity, mode (zero paint/one erase), dispatch origin x/y.
    var controls: SIMD4<Float>
    /// One when texture 1 contains a captured selection clip, then the
    /// tile's canvas origin, which anchors grain outside tile-local space.
    var clipControl: SIMD4<Float>
  }

  private struct StampWork {
    var stamp: BrushStamp
    var stroke: PaintStroke
    var strokeIndex: Int
    var clipRecipeData: Data?
  }

  private let device: any MTLDevice
  private let commandQueue: any MTLCommandQueue
  private let context: CIContext
  private let maskRenderer: MaskRenderer
  private let workingColorSpace: CGColorSpace
  private let fullClipTexture: any MTLTexture
  private let emptyClipTexture: any MTLTexture
  private let clearRGBA: any MTLComputePipelineState
  private let clearMask: any MTLComputePipelineState
  private let stampRGBA: any MTLComputePipelineState
  private let stampRGBARestrained: any MTLComputePipelineState
  private let stampMask: any MTLComputePipelineState
  private let compositeRGBA: any MTLComputePipelineState
  private var caches: [SurfaceKey: CachedSurface] = [:]
  private var clipImages: [ClipSurfaceKey: CachedClipImage] = [:]
  private var clipTiles: [ClipTileKey: any MTLTexture] = [:]
  private var totalBytes = 0
  private var accessCounter: UInt64 = 0

  init(
    device: any MTLDevice,
    context: CIContext,
    maskRenderer: MaskRenderer,
    workingColorSpace: CGColorSpace
  ) throws {
    guard let commandQueue = device.makeCommandQueue() else {
      throw PixeltjeMacError("Metal unavailable", "Could not create the brush command queue.")
    }
    let library: any MTLLibrary
    do {
      library = try device.makeLibrary(source: Self.shaderSource, options: nil)
    } catch {
      throw PixeltjeMacError("Brush unavailable", "The Metal brush kernels could not compile: \(error.localizedDescription)")
    }
    func pipeline(_ name: String) throws -> any MTLComputePipelineState {
      guard let function = library.makeFunction(name: name) else {
        throw PixeltjeMacError("Brush unavailable", "The Metal brush kernel \(name) is missing.")
      }
      return try device.makeComputePipelineState(function: function)
    }
    func solidClipTexture(_ value: Float16) throws -> any MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r16Float,
        width: Self.tileSize,
        height: Self.tileSize,
        mipmapped: false
      )
      descriptor.usage = .shaderRead
      descriptor.storageMode = .shared
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw PixeltjeMacError("Brush unavailable", "Could not allocate a selection clip texture.")
      }
      var values = [Float16](repeating: value, count: Self.tileSize * Self.tileSize)
      texture.replace(
        region: MTLRegionMake2D(0, 0, Self.tileSize, Self.tileSize),
        mipmapLevel: 0,
        withBytes: &values,
        bytesPerRow: Self.tileSize * MemoryLayout<Float16>.size
      )
      return texture
    }

    self.device = device
    self.commandQueue = commandQueue
    self.context = context
    self.maskRenderer = maskRenderer
    self.workingColorSpace = workingColorSpace
    self.fullClipTexture = try solidClipTexture(1)
    self.emptyClipTexture = try solidClipTexture(0)
    clearRGBA = try pipeline("clearRGBA")
    clearMask = try pipeline("clearMask")
    stampRGBA = try pipeline("stampRGBA")
    stampRGBARestrained = try pipeline("stampRGBARestrained")
    stampMask = try pipeline("stampMask")
    compositeRGBA = try pipeline("compositeRGBA")
  }

  func clearCaches() {
    caches.removeAll(keepingCapacity: false)
    clipImages.removeAll(keepingCapacity: false)
    clipTiles.removeAll(keepingCapacity: false)
    totalBytes = 0
  }

  func removeSurface(cacheID: String) {
    let keys = caches.keys.filter { $0.id == cacheID }
    for key in keys {
      if let removed = caches.removeValue(forKey: key) {
        totalBytes -= bytes(of: removed)
      }
    }
  }

  func render(_ request: StrokeSurfaceRequest) throws -> StrokeSurfaceFrame {
    guard request.width > 0, request.height > 0,
      request.width <= BrushLimits.maximumCanvasAxis,
      request.height <= BrushLimits.maximumCanvasAxis
    else {
      throw PixeltjeMacError(
        "Paint surface unavailable",
        "The paint canvas must be between 1 and \(BrushLimits.maximumCanvasAxis) pixels on each axis."
      )
    }
    for stroke in request.recipe.strokes
    where !(stroke.engineVersion == .version1 || stroke.engineVersion == .current) {
      throw PixeltjeMacError(
        "Unsupported brush engine",
        "This stroke uses brush engine \(stroke.engineVersion.rawValue); this app renders versions 1 through \(BrushEngineVersion.current.rawValue)."
      )
    }

    let key = SurfaceKey(
      id: request.cacheID,
      kind: request.recipe.kind,
      width: request.width,
      height: request.height
    )
    accessCounter &+= 1
    var cached = caches.removeValue(forKey: key) ?? CachedSurface(
      recipe: StrokeSurfaceRecipe(kind: request.recipe.kind),
      tiles: [:],
      lastAccess: accessCounter
    )
    let plan = incrementalWork(from: cached.recipe, to: request.recipe)
    if plan.rebuild {
      totalBytes -= bytes(of: cached)
      cached.tiles.removeAll(keepingCapacity: false)
    }
    cached.recipe = request.recipe
    cached.lastAccess = accessCounter

    if !plan.work.isEmpty {
      do {
        try encode(
          plan.work,
          into: &cached,
          key: key,
          width: request.width,
          height: request.height,
          kind: request.recipe.kind
        )
      } catch {
        totalBytes -= bytes(of: cached)
        throw error
      }
    }
    caches[key] = cached
    evictIfNeeded(preserving: key)
    guard let stored = caches[key] else {
      throw PixeltjeMacError("Paint memory limit", "The brush surface exceeded its memory budget.")
    }
    return frame(for: key, cached: stored)
  }

  func readPixels(_ request: StrokeSurfaceRequest) throws -> StrokeSurfacePixels {
    _ = try render(request)
    let key = SurfaceKey(
      id: request.cacheID,
      kind: request.recipe.kind,
      width: request.width,
      height: request.height
    )
    guard let cached = caches[key] else {
      return StrokeSurfacePixels(
        width: request.width,
        height: request.height,
        componentCount: request.recipe.kind == .colorRGBA ? 4 : 1,
        values: []
      )
    }
    let components = request.recipe.kind == .colorRGBA ? 4 : 1
    let base = request.recipe.kind == .mask ? Float(request.recipe.initialCoverage) : 0
    var output = [Float](repeating: base, count: request.width * request.height * components)
    for (coordinate, tile) in cached.tiles {
      let validWidth = min(Self.tileSize, request.width - coordinate.x * Self.tileSize)
      let validHeight = min(Self.tileSize, request.height - coordinate.y * Self.tileSize)
      var half = [Float16](repeating: 0, count: Self.tileSize * Self.tileSize * components)
      tile.texture.getBytes(
        &half,
        bytesPerRow: Self.tileSize * components * MemoryLayout<Float16>.size,
        from: MTLRegionMake2D(0, 0, Self.tileSize, Self.tileSize),
        mipmapLevel: 0
      )
      for y in 0..<validHeight {
        for x in 0..<validWidth {
          let source = (y * Self.tileSize + x) * components
          let destination =
            ((coordinate.y * Self.tileSize + y) * request.width
              + coordinate.x * Self.tileSize + x) * components
          for component in 0..<components {
            output[destination + component] = Float(half[source + component])
          }
        }
      }
    }
    return StrokeSurfacePixels(
      width: request.width,
      height: request.height,
      componentCount: components,
      values: output
    )
  }

  func colorImage(
    for request: StrokeSurfaceRequest,
    workingColorSpace: CGColorSpace
  ) throws -> CIImage? {
    guard request.recipe.kind == .colorRGBA else { return nil }
    _ = try render(request)
    let key = SurfaceKey(
      id: request.cacheID,
      kind: request.recipe.kind,
      width: request.width,
      height: request.height
    )
    guard let cached = caches[key] else { return nil }
    let extent = CGRect(x: 0, y: 0, width: request.width, height: request.height)
    var image = CIImage(color: .clear).cropped(to: extent)
    for coordinate in cached.tiles.keys.sorted() {
      guard let tile = cached.tiles[coordinate] else { continue }
      guard
        let tileImage = CIImage(
          mtlTexture: tile.texture,
          options: [.colorSpace: workingColorSpace]
        )
      else {
        throw PixeltjeMacError(
          "Brush rendering failed",
          "Metal could not expose a paint tile to Core Image."
        )
      }
      let x = coordinate.x * Self.tileSize
      let y = coordinate.y * Self.tileSize
      let validWidth = min(Self.tileSize, request.width - x)
      let validHeight = min(Self.tileSize, request.height - y)
      let placed = tileImage
        .cropped(to: CGRect(x: 0, y: 0, width: validWidth, height: validHeight))
        .transformed(by: CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y)))
      image = placed.composited(over: image)
    }
    return image.cropped(to: extent)
  }

  /// Exposes an r16Float stroke surface as opaque grayscale mask coverage.
  /// Untouched tiles come from `initialCoverage`, so Reveal All remains sparse
  /// and does not allocate a canvas-sized texture.
  func maskCoverageImage(for request: StrokeSurfaceRequest) throws -> CIImage? {
    guard request.recipe.kind == .mask else { return nil }
    _ = try render(request)
    let key = SurfaceKey(
      id: request.cacheID,
      kind: request.recipe.kind,
      width: request.width,
      height: request.height
    )
    guard let cached = caches[key] else { return nil }
    let extent = CGRect(x: 0, y: 0, width: request.width, height: request.height)
    let initial = CGFloat(request.recipe.initialCoverage)
    var image = CIImage(
      color: CIColor(red: initial, green: initial, blue: initial, alpha: 1)
    ).cropped(to: extent)
    let gray = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
    for coordinate in cached.tiles.keys.sorted() {
      guard let tile = cached.tiles[coordinate],
        let raw = CIImage(mtlTexture: tile.texture, options: [.colorSpace: gray])
      else { continue }
      let x = coordinate.x * Self.tileSize
      let y = coordinate.y * Self.tileSize
      let validWidth = min(Self.tileSize, request.width - x)
      let validHeight = min(Self.tileSize, request.height - y)
      let opaque = raw.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        .cropped(to: CGRect(x: 0, y: 0, width: validWidth, height: validHeight))
        .transformed(by: CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y)))
      image = opaque.composited(over: image)
    }
    return image.cropped(to: extent)
  }

  private func incrementalWork(
    from old: StrokeSurfaceRecipe,
    to new: StrokeSurfaceRecipe
  ) -> (rebuild: Bool, work: [StampWork]) {
    guard old.kind == new.kind else { return (true, allWork(in: new)) }
    if old == new { return (false, []) }

    if new.strokes.count >= old.strokes.count,
      Array(new.strokes.prefix(old.strokes.count)) == old.strokes
    {
      return (
        false,
        new.strokes.enumerated().dropFirst(old.strokes.count).flatMap { work(for: $0.element, index: $0.offset) }
      )
    }

    // A provisional stroke is repeatedly submitted with more samples. Fixed
    // distance interpolation makes all already-emitted stamps a stable prefix.
    if old.strokes.count == new.strokes.count,
      let oldLast = old.strokes.last,
      let newLast = new.strokes.last,
      Array(old.strokes.dropLast()) == Array(new.strokes.dropLast()),
      sameBrushIdentity(oldLast, newLast),
      newLast.samples.starts(with: oldLast.samples)
    {
      // A restrained stroke keeps the maximum coverage of its own stamps, so a
      // grown tail cannot be appended over coverage that is already there: its
      // isolated scratch has to be rebuilt from every stamp. Only this one
      // stroke pays for that. Completed strokes stay on the incremental path.
      if requiresStrokeIsolation(newLast) { return (true, allWork(in: new)) }
      let previousCount = oldLast.interpolatedStamps().count
      let appended = newLast.interpolatedStamps().dropFirst(previousCount)
      let clipData = encodedClip(newLast.selectionClip)
      return (
        false,
        appended.map { StampWork(stamp: $0, stroke: newLast, strokeIndex: new.strokes.count - 1, clipRecipeData: clipData) }
      )
    }

    return (true, allWork(in: new))
  }

  private func sameBrushIdentity(_ first: PaintStroke, _ second: PaintStroke) -> Bool {
    first.engineVersion == second.engineVersion
      && first.seed == second.seed
      && first.mode == second.mode
      && first.settings == second.settings
      && first.color == second.color
      && first.selectionClip == second.selectionClip
  }

  private func requiresStrokeIsolation(_ stroke: PaintStroke) -> Bool {
    stroke.mode == .paint && stroke.brush?.deposition == .restrained
  }

  private func allWork(in recipe: StrokeSurfaceRecipe) -> [StampWork] {
    recipe.strokes.enumerated().flatMap { work(for: $0.element, index: $0.offset) }
  }

  private func work(for stroke: PaintStroke, index: Int) -> [StampWork] {
    let clipData = encodedClip(stroke.selectionClip)
    return stroke.interpolatedStamps().map {
      StampWork(stamp: $0, stroke: stroke, strokeIndex: index, clipRecipeData: clipData)
    }
  }

  private func encodedClip(_ clip: MaskRecipe?) -> Data? {
    guard let clip else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(clip)
  }

  private func encode(
    _ work: [StampWork],
    into cached: inout CachedSurface,
    key: SurfaceKey,
    width: Int,
    height: Int,
    kind: StrokeSurfaceKind
  ) throws {
    guard kind == .colorRGBA, work.contains(where: { requiresStrokeIsolation($0.stroke) }) else {
      try encodeDirect(work, into: &cached, key: key, width: width, height: height, kind: kind, restrained: false)
      return
    }

    var start = 0
    while start < work.count {
      let stroke = work[start].stroke
      var end = start + 1
      while end < work.count, work[end].strokeIndex == work[start].strokeIndex { end += 1 }
      let group = Array(work[start..<end])
      if requiresStrokeIsolation(stroke) {
        var scratch = CachedSurface(
          recipe: StrokeSurfaceRecipe(kind: .colorRGBA), tiles: [:], lastAccess: accessCounter)
        do {
          try encodeDirect(group, into: &scratch, key: key, width: width, height: height, kind: .colorRGBA, restrained: true)
          try composite(scratch, over: &cached, key: key)
        } catch {
          totalBytes -= bytes(of: scratch)
          throw error
        }
        totalBytes -= bytes(of: scratch)
      } else {
        try encodeDirect(group, into: &cached, key: key, width: width, height: height, kind: kind, restrained: false)
      }
      start = end
    }
  }

  private func encodeDirect(
    _ work: [StampWork],
    into cached: inout CachedSurface,
    key: SurfaceKey,
    width: Int,
    height: Int,
    kind: StrokeSurfaceKind,
    restrained: Bool
  ) throws {
    try Task.checkCancellation()
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
      throw PixeltjeMacError("Brush unavailable", "Could not encode a Metal brush command.")
    }
    var didEndEncoding = false
    defer {
      if !didEndEncoding { encoder.endEncoding() }
    }
    for item in work {
      try Task.checkCancellation()
      let radiusX = max(item.stamp.diameter / 2, 0.125)
      let radiusY = max(radiusX * item.stamp.aspectRatio, 0.125)
      // The circle every rotation of this footprint fits inside. An ellipse
      // reaches its major semi-axis; a rectangle reaches its corner, which is
      // further out, so taking the larger axis alone would clip the corners.
      let radius = item.stamp.shape == .roundedRectangle
        ? (radiusX * radiusX + radiusY * radiusY).squareRoot()
        : max(radiusX, radiusY)
      let minimumX = max(Int(floor(item.stamp.x - radius - 1)), 0)
      let minimumY = max(Int(floor(item.stamp.y - radius - 1)), 0)
      let maximumX = min(Int(ceil(item.stamp.x + radius + 1)), width - 1)
      let maximumY = min(Int(ceil(item.stamp.y + radius + 1)), height - 1)
      guard minimumX <= maximumX, minimumY <= maximumY, item.stamp.opacity > 0 else { continue }

      let firstTileX = minimumX / Self.tileSize
      let lastTileX = maximumX / Self.tileSize
      let firstTileY = minimumY / Self.tileSize
      let lastTileY = maximumY / Self.tileSize
      for tileY in firstTileY...lastTileY {
        for tileX in firstTileX...lastTileX {
          let coordinate = TileCoordinate(x: tileX, y: tileY)
          if cached.tiles[coordinate] == nil {
            // Erasing a tile that has never held coverage is a no-op and must
            // not allocate transparent storage.
            if item.stroke.mode == .erase && cached.recipe.initialCoverage <= 0 { continue }
            let tile = try makeTile(kind: kind, preserving: key)
            cached.tiles[coordinate] = tile
            totalBytes += bytesPerTile(kind: kind)
            encodeClear(
              tile.texture,
              kind: kind,
              initialCoverage: cached.recipe.initialCoverage,
              using: encoder)
          }
          guard let tile = cached.tiles[coordinate] else { continue }

          let tileOriginX = tileX * Self.tileSize
          let tileOriginY = tileY * Self.tileSize
          let localMinimumX = max(minimumX - tileOriginX, 0)
          let localMinimumY = max(minimumY - tileOriginY, 0)
          let localMaximumX = min(maximumX - tileOriginX, Self.tileSize - 1)
          let localMaximumY = min(maximumY - tileOriginY, Self.tileSize - 1)
          var parameters = StampParameters(
            geometry: SIMD4(
              Float(item.stamp.x - Double(tileOriginX)),
              Float(item.stamp.y - Double(tileOriginY)),
              Float(radiusX),
              Float(radiusY)
            ),
            appearance: SIMD4(
              Float(cos(item.stamp.angleRadians)),
              Float(sin(item.stamp.angleRadians)),
              Float(item.stroke.settings.hardness),
              item.stamp.shape == .roundedRectangle ? 2 : (item.stamp.shape == .ellipse ? 1 : 0)
            ),
            texture: SIMD4(
              Float(item.stamp.grainAmount),
              item.stamp.grain == .none ? 0 : (item.stamp.grain == .bristles ? 2 : (item.stamp.grain == .wash ? 3 : 1)),
              // A small offset on purpose. The grain hash multiplies its input,
              // so a canvas-scale coordinate plus a seed of any real size
              // leaves float32's exact range and collapses fract() to zero.
              Float(item.stroke.seed & 0x1FF) + Float((item.stroke.seed >> 9) & 0xFF) / 256,
              0
            ),
            color: SIMD4(
              Float(item.stroke.color.red),
              Float(item.stroke.color.green),
              Float(item.stroke.color.blue),
              Float(item.stroke.color.alpha)
            ),
            controls: SIMD4(
              Float(item.stamp.opacity),
              item.stroke.mode == .erase ? 1 : 0,
              Float(localMinimumX),
              Float(localMinimumY)
            ),
            clipControl: SIMD4(
              item.stroke.selectionClip == nil ? 0 : 1,
              Float(tileOriginX),
              Float(tileOriginY),
              0
            )
          )
          encoder.setComputePipelineState(
            kind == .colorRGBA ? (restrained ? stampRGBARestrained : stampRGBA) : stampMask)
          encoder.setTexture(tile.texture, index: 0)
          let clipTexture = try selectionClipTexture(
            item.stroke.selectionClip,
            recipeData: item.clipRecipeData,
            width: width,
            height: height,
            coordinate: coordinate
          )
          encoder.setTexture(clipTexture, index: 1)
          encoder.setBytes(&parameters, length: MemoryLayout<StampParameters>.stride, index: 0)
          dispatch(
            width: localMaximumX - localMinimumX + 1,
            height: localMaximumY - localMinimumY + 1,
            encoder: encoder
          )
        }
      }
    }
    encoder.endEncoding()
    didEndEncoding = true
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
      throw PixeltjeMacError(
        "Brush rendering failed",
        commandBuffer.error?.localizedDescription ?? "The Metal brush command did not complete."
      )
    }
    try Task.checkCancellation()
  }

  /// Composites a completed isolated marker stroke onto the accumulated layer.
  /// The scratch surface is discarded immediately after this call.
  private func composite(_ source: CachedSurface, over destination: inout CachedSurface, key: SurfaceKey) throws {
    guard !source.tiles.isEmpty else { return }
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else { throw PixeltjeMacError("Brush unavailable", "Could not composite a marker stroke.") }
    for (coordinate, sourceTile) in source.tiles {
      if destination.tiles[coordinate] == nil {
        let tile = try makeTile(kind: .colorRGBA, preserving: key)
        destination.tiles[coordinate] = tile
        totalBytes += bytesPerTile(kind: .colorRGBA)
        encodeClear(tile.texture, kind: .colorRGBA, initialCoverage: 0, using: encoder)
      }
      guard let target = destination.tiles[coordinate] else { continue }
      encoder.setComputePipelineState(compositeRGBA)
      encoder.setTexture(target.texture, index: 0)
      encoder.setTexture(sourceTile.texture, index: 1)
      dispatch(width: Self.tileSize, height: Self.tileSize, encoder: encoder)
    }
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
      throw PixeltjeMacError("Brush rendering failed", commandBuffer.error?.localizedDescription ?? "Could not composite marker stroke.")
    }
  }

  private func selectionClipTexture(
    _ selection: MaskRecipe?,
    recipeData: Data?,
    width: Int,
    height: Int,
    coordinate: TileCoordinate
  ) throws -> any MTLTexture {
    guard let selection, let recipeData else { return fullClipTexture }
    let surfaceKey = ClipSurfaceKey(recipe: recipeData, width: width, height: height)
    let tileKey = ClipTileKey(surface: surfaceKey, coordinate: coordinate)
    if let cached = clipTiles[tileKey] { return cached }

    accessCounter &+= 1
    let coverage: CIImage?
    if let cached = clipImages[surfaceKey] {
      coverage = cached.image
      clipImages[surfaceKey]?.lastAccess = accessCounter
    } else {
      coverage = try maskRenderer.evaluate(
        selection,
        in: MaskSpace(
          extent: CGRect(x: 0, y: 0, width: width, height: height),
          pixelsPerCanvasPixel: 1
        ),
        source: nil,
        sourceIdentity: "paint-selection"
      )
      if let coverage {
        clipImages[surfaceKey] = CachedClipImage(image: coverage, lastAccess: accessCounter)
        evictOldClipImages(preserving: surfaceKey)
      }
    }
    guard let coverage else { return emptyClipTexture }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r16Float,
      width: Self.tileSize,
      height: Self.tileSize,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw PixeltjeMacError("Brush unavailable", "Could not allocate a selection clip tile.")
    }
    let originX = coordinate.x * Self.tileSize
    let originY = coordinate.y * Self.tileSize
    let validWidth = min(Self.tileSize, width - originX)
    let validHeight = min(Self.tileSize, height - originY)
    let sourceRect = CGRect(x: originX, y: originY, width: validWidth, height: validHeight)
    let local = coverage
      .cropped(to: sourceRect)
      .transformed(by: CGAffineTransform(translationX: -CGFloat(originX), y: -CGFloat(originY)))
    context.render(
      local,
      to: texture,
      commandBuffer: nil,
      bounds: CGRect(x: 0, y: 0, width: validWidth, height: validHeight),
      colorSpace: workingColorSpace
    )
    clipTiles[tileKey] = texture
    if clipTiles.count > 512 {
      clipTiles = clipTiles.filter { $0.key.surface == surfaceKey }
    }
    return texture
  }

  private func evictOldClipImages(preserving key: ClipSurfaceKey) {
    while clipImages.count > 2 {
      guard let victim = clipImages
        .filter({ $0.key != key })
        .min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
      else { return }
      clipImages.removeValue(forKey: victim)
      clipTiles = clipTiles.filter { $0.key.surface != victim }
    }
  }

  private func encodeClear(
    _ texture: any MTLTexture,
    kind: StrokeSurfaceKind,
    initialCoverage: Double,
    using encoder: any MTLComputeCommandEncoder
  ) {
    encoder.setComputePipelineState(kind == .colorRGBA ? clearRGBA : clearMask)
    encoder.setTexture(texture, index: 0)
    if kind == .mask {
      var value = Float(initialCoverage)
      encoder.setBytes(&value, length: MemoryLayout<Float>.stride, index: 0)
    }
    dispatch(width: Self.tileSize, height: Self.tileSize, encoder: encoder)
  }

  private func dispatch(
    width: Int,
    height: Int,
    encoder: any MTLComputeCommandEncoder
  ) {
    encoder.dispatchThreads(
      MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
    )
  }

  private func makeTile(kind: StrokeSurfaceKind, preserving key: SurfaceKey) throws -> Tile {
    let tileBytes = bytesPerTile(kind: kind)
    evictUntilAdding(bytes: tileBytes, preserving: key)
    guard totalBytes + tileBytes <= Self.memoryBudget else {
      throw PixeltjeMacError(
        "Paint memory limit",
        "This painted area exceeds the \(Self.memoryBudget / 1_024 / 1_024) MiB brush cache limit."
      )
    }
    let bytesPerElement = kind == .colorRGBA ? 8 : 2
    let pixelFormat: OSType =
      kind == .colorRGBA
      ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_OneComponent16Half
    guard let surface = IOSurface(properties: [
      .width: Self.tileSize,
      .height: Self.tileSize,
      .bytesPerElement: bytesPerElement,
      .pixelFormat: pixelFormat,
      .name: kind == .colorRGBA ? "Pixeltje Paint RGBA16F Tile" : "Pixeltje Mask R16F Tile",
    ]) else {
      throw PixeltjeMacError("Paint allocation failed", "Could not allocate a brush tile.")
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: kind == .colorRGBA ? .rgba16Float : .r16Float,
      width: Self.tileSize,
      height: Self.tileSize,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
      throw PixeltjeMacError("Paint allocation failed", "Metal could not map a brush tile.")
    }
    return Tile(surface: surface, texture: texture)
  }

  private func frame(for key: SurfaceKey, cached: CachedSurface) -> StrokeSurfaceFrame {
    let tiles = cached.tiles.keys.sorted().compactMap { coordinate -> StrokeSurfaceTile? in
      guard let tile = cached.tiles[coordinate] else { return nil }
      let x = coordinate.x * Self.tileSize
      let y = coordinate.y * Self.tileSize
      return StrokeSurfaceTile(
        x: x,
        y: y,
        width: min(Self.tileSize, key.width - x),
        height: min(Self.tileSize, key.height - y),
        surface: tile.surface
      )
    }
    return StrokeSurfaceFrame(
      cacheID: key.id,
      kind: key.kind,
      width: key.width,
      height: key.height,
      tiles: tiles
    )
  }

  private func bytesPerTile(kind: StrokeSurfaceKind) -> Int {
    Self.tileSize * Self.tileSize * (kind == .colorRGBA ? 8 : 2)
  }

  private func bytes(of surface: CachedSurface) -> Int {
    surface.tiles.count * bytesPerTile(kind: surface.recipe.kind)
  }

  private func evictIfNeeded(preserving key: SurfaceKey) {
    evictUntilAdding(bytes: 0, preserving: key)
  }

  private func evictUntilAdding(bytes: Int, preserving key: SurfaceKey) {
    while totalBytes + bytes > Self.memoryBudget {
      guard let victim = caches
        .filter({ $0.key != key })
        .min(by: { $0.value.lastAccess < $1.value.lastAccess })
      else { return }
      totalBytes -= self.bytes(of: victim.value)
      caches.removeValue(forKey: victim.key)
    }
  }

  private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct StampParameters {
      float4 geometry;
      float4 appearance;
      float4 texture;
      float4 color;
      float4 controls;
      float4 clipControl;
    };

    kernel void clearRGBA(texture2d<half, access::write> target [[texture(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
      target.write(half4(0.0h), gid);
    }

    kernel void clearMask(texture2d<half, access::write> target [[texture(0)]],
                          constant float& initialCoverage [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
      target.write(half4(half(initialCoverage), 0.0h, 0.0h, 1.0h), gid);
    }

    // Deterministic value noise over canonical canvas pixels. The multiplier
    // is deliberately small: a large one pushes canvas-scale coordinates past
    // the range where float32 still resolves single pixels, and fract() then
    // returns a constant, which erases the grain instead of texturing it.
    float hash21(float2 position) {
      float3 scattered = fract(float3(position.x, position.y, position.x) * 0.1031f);
      scattered += dot(scattered, scattered.yzx + 33.33f);
      return fract((scattered.x + scattered.y) * scattered.z);
    }

    float stampCoverage(constant StampParameters& stamp, uint2 gid) {
      float2 pixel = float2(gid) + stamp.controls.zw + 0.5f;
      // Coverage is measured against a tile-local stamp centre; grain is not.
      // Anchoring grain in canvas space keeps one texture running across a
      // tile boundary instead of restarting in every tile.
      float2 canvasPixel = pixel + stamp.clipControl.yz;
      float2 delta = pixel - stamp.geometry.xy;
      float2 local = float2(
        delta.x * stamp.appearance.x + delta.y * stamp.appearance.y,
        -delta.x * stamp.appearance.y + delta.y * stamp.appearance.x
      );
      float2 normalized = abs(local / max(stamp.geometry.zw, float2(0.125f)));
      float tipShape = stamp.appearance.w;
      float distanceFromCenter = tipShape > 1.5f
        ? max(normalized.x, normalized.y)
        : length(normalized);
      float hardness = clamp(stamp.appearance.z, 0.0f, 1.0f);
      float edge = hardness >= 0.9999f
        ? (distanceFromCenter <= 1.0f ? 1.0f : 0.0f)
        : 1.0f - smoothstep(hardness, 1.0f, distanceFromCenter);
      float grainAmount = clamp(stamp.texture.x, 0.0f, 1.0f);
      if (grainAmount > 0.0f) {
        float grain = hash21(canvasPixel + stamp.texture.zz);
        if (stamp.texture.y > 1.5f && stamp.texture.y < 2.5f) {
          // Bristles streak along the tip, so they vary across its width and
          // stay constant along its length. Normalizing by the minor radius
          // keeps the bristle count steady at every brush size.
          float acrossTip = local.y / max(stamp.geometry.w, 0.125f);
          grain = 0.55f + 0.45f * sin(acrossTip * 9.0f + stamp.texture.z);
        } else if (stamp.texture.y > 2.5f) {
          grain = 0.72f + 0.28f * hash21(floor(canvasPixel * 0.25f) + stamp.texture.zz);
        }
        edge *= mix(1.0f, grain, grainAmount);
      }
      return clamp(edge * stamp.controls.x, 0.0f, 1.0f);
    }

    kernel void stampRGBA(texture2d<half, access::read_write> target [[texture(0)]],
                          texture2d<half, access::read> clip [[texture(1)]],
                          constant StampParameters& stamp [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
      uint2 pixel = gid + uint2(stamp.controls.zw);
      float coverage = stampCoverage(stamp, gid);
      if (stamp.clipControl.x > 0.5f) {
        coverage *= float(clip.read(pixel).r);
      }
      float4 destination = float4(target.read(pixel));
      if (stamp.controls.y > 0.5f) {
        destination *= 1.0f - coverage;
      } else {
        float sourceAlpha = stamp.color.a * coverage;
        float3 source = stamp.color.rgb * sourceAlpha;
        destination = float4(
          source + destination.rgb * (1.0f - sourceAlpha),
          sourceAlpha + destination.a * (1.0f - sourceAlpha)
        );
      }
      target.write(half4(destination), pixel);
    }

    // Used only on a transparent, stroke-local scratch tile. Keeping the
    // strongest contribution makes a highlighter/marker even where its own
    // stamps overlap. The scratch is then composited once over the layer.
    kernel void stampRGBARestrained(texture2d<half, access::read_write> target [[texture(0)]],
                                    texture2d<half, access::read> clip [[texture(1)]],
                                    constant StampParameters& stamp [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
      uint2 pixel = gid + uint2(stamp.controls.zw);
      float coverage = stampCoverage(stamp, gid);
      if (stamp.clipControl.x > 0.5f) {
        coverage *= float(clip.read(pixel).r);
      }
      float4 destination = float4(target.read(pixel));
      float sourceAlpha = stamp.color.a * coverage;
      float alpha = max(destination.a, sourceAlpha);
      target.write(half4(half3(stamp.color.rgb * alpha), half(alpha)), pixel);
    }

    kernel void compositeRGBA(texture2d<half, access::read_write> target [[texture(0)]],
                              texture2d<half, access::read> source [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
      float4 destination = float4(target.read(gid));
      float4 foreground = float4(source.read(gid));
      target.write(half4(float4(
        foreground.rgb + destination.rgb * (1.0f - foreground.a),
        foreground.a + destination.a * (1.0f - foreground.a)
      )), gid);
    }

    kernel void stampMask(texture2d<half, access::read_write> target [[texture(0)]],
                          texture2d<half, access::read> clip [[texture(1)]],
                          constant StampParameters& stamp [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
      uint2 pixel = gid + uint2(stamp.controls.zw);
      float coverage = stampCoverage(stamp, gid);
      if (stamp.clipControl.x > 0.5f) {
        coverage *= float(clip.read(pixel).r);
      }
      float destination = float(target.read(pixel).r);
      float result = stamp.controls.y > 0.5f
        ? destination * (1.0f - coverage)
        : coverage + destination * (1.0f - coverage);
      target.write(half4(half(result), 0.0h, 0.0h, 1.0h), pixel);
    }
    """
}
