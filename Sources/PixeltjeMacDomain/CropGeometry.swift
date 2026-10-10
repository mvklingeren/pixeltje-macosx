import Foundation

// MARK: - Adapters into and out of the canonical image coordinate space
//
// `CropRecipe` is written in unit fractions of the oriented image (see the note
// at the top of `CropRecipe.swift`). Everything that needs pixels — the render
// engine's crop stage, the canvas's overlay, the canvas extent a document
// adopts — crosses one of the adapters here rather than repeating the
// arithmetic. Nothing in this file knows about Core Image, AppKit or Metal:
// the crossing into those coordinate systems happens once, at their edge.

/// A rectangle in the canonical image coordinate space, in pixels.
///
/// Origin bottom-left, x to the right, y up, matching `CropRecipe`.
public struct CropPixelRect: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var centerX: Double { x + width / 2 }
  public var centerY: Double { y + height / 2 }
  public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// Which part of the crop rectangle a drag is holding.
public enum CropHandle: String, CaseIterable, Equatable, Sendable {
  case bottomLeft
  case bottomRight
  case topLeft
  case topRight
  case left
  case right
  case bottom
  case top

  public var movesLeftEdge: Bool {
    self == .bottomLeft || self == .topLeft || self == .left
  }

  public var movesRightEdge: Bool {
    self == .bottomRight || self == .topRight || self == .right
  }

  public var movesBottomEdge: Bool {
    self == .bottomLeft || self == .bottomRight || self == .bottom
  }

  public var movesTopEdge: Bool {
    self == .topLeft || self == .topRight || self == .top
  }

  /// The unit position this handle sits at inside a crop rectangle.
  public func position(in crop: CropRecipe) -> (x: Double, y: Double) {
    let x =
      movesLeftEdge ? crop.left : (movesRightEdge ? crop.right : crop.centerX)
    let y =
      movesBottomEdge ? crop.bottom : (movesTopEdge ? crop.top : crop.centerY)
    return (x, y)
  }
}

public enum CropGeometry {
  /// How many binary-search steps `fitted` takes when shrinking a crop back
  /// inside a straightened image. Twenty-four halvings resolve a unit edge to
  /// well under a pixel on any image this application opens, and a fixed count
  /// keeps the result deterministic.
  private static let fitIterations = 24

  // MARK: - EXIF orientation

  /// The oriented image size, from the decoder's sensor-oriented native size.
  ///
  /// EXIF orientations 5 through 8 carry a quarter turn, so the oriented image
  /// is the native size transposed. This is the one place that knowledge lives;
  /// the render engine applies the orientation itself exactly once, through
  /// Core Image.
  public static func orientedSize(
    nativeWidth: Int,
    nativeHeight: Int,
    exifOrientation: Int
  ) -> (width: Double, height: Double) {
    let width = Double(nativeWidth)
    let height = Double(nativeHeight)
    return [5, 6, 7, 8].contains(exifOrientation)
      ? (width: height, height: width)
      : (width: width, height: height)
  }

  // MARK: - Unit and pixel rectangles

  /// The crop rectangle in pixels of an image of this size.
  public static func pixelRect(
    _ crop: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> CropPixelRect {
    let crop = crop.clamped
    return CropPixelRect(
      x: crop.left * imageWidth,
      y: crop.bottom * imageHeight,
      width: crop.unitWidth * imageWidth,
      height: crop.unitHeight * imageHeight
    )
  }

  /// The same rectangle back in unit coordinates, keeping the recipe's angle,
  /// aspect lock and overlay.
  public static func unitCrop(
    _ rect: CropPixelRect,
    imageWidth: Double,
    imageHeight: Double,
    like recipe: CropRecipe
  ) -> CropRecipe {
    guard imageWidth > 0, imageHeight > 0 else { return recipe }
    var updated = recipe
    updated.left = rect.x / imageWidth
    updated.bottom = rect.y / imageHeight
    updated.right = rect.maxX / imageWidth
    updated.top = rect.maxY / imageHeight
    return updated.clamped
  }

  /// The pixel size a document takes on after straighten and crop.
  ///
  /// The straighten turns the image underneath an axis-aligned rectangle, so
  /// the rendered extent is the crop rectangle itself.
  public static func croppedPixelSize(
    _ crop: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> (width: Int, height: Int) {
    let rect = pixelRect(crop, imageWidth: imageWidth, imageHeight: imageHeight)
    return (width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
  }

  // MARK: - Aspect ratios

  /// The width-to-height ratio a crop's own rectangle currently has, in pixels.
  public static func pixelAspect(
    _ crop: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> Double? {
    let rect = pixelRect(crop, imageWidth: imageWidth, imageHeight: imageHeight)
    guard rect.width > 0, rect.height > 0 else { return nil }
    return rect.width / rect.height
  }

  /// The locked pixel ratio expressed in unit coordinates.
  ///
  /// Unit space is not square — it is the image stretched to 1×1 — so a 3:2
  /// pixel lock is a different number of unit widths per unit height on every
  /// image shape. Handle dragging works in unit space, so it needs this.
  private static func unitAspect(
    _ aspect: CropAspectRatio,
    imageWidth: Double,
    imageHeight: Double
  ) -> Double? {
    guard imageWidth > 0, imageHeight > 0,
      let pixelRatio = aspect.value(imageWidth: imageWidth, imageHeight: imageHeight),
      pixelRatio > 0
    else { return nil }
    return pixelRatio * imageHeight / imageWidth
  }

  // MARK: - Straighten

  /// Whether every corner of the crop rectangle still lands on real pixels once
  /// the image has been turned by the straighten angle.
  ///
  /// The image rotates about its center underneath a fixed rectangle, so a
  /// corner is inside exactly when turning it back by the same angle puts it
  /// within the unrotated image.
  public static func isInsideStraightenedImage(
    _ crop: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> Bool {
    let crop = crop.clamped
    guard imageWidth > 0, imageHeight > 0 else { return false }
    guard crop.angleDegrees != 0 else {
      return crop.left >= 0 && crop.bottom >= 0 && crop.right <= 1 && crop.top <= 1
    }
    let radians = -crop.angleDegrees * .pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    let centerX = imageWidth / 2
    let centerY = imageHeight / 2
    let rect = pixelRect(crop, imageWidth: imageWidth, imageHeight: imageHeight)
    let corners = [
      (rect.x, rect.y), (rect.maxX, rect.y), (rect.x, rect.maxY), (rect.maxX, rect.maxY),
    ]
    // A hair of slack: a rectangle produced by `fitted` sits exactly on the
    // boundary, and exact arithmetic there would reject its own result.
    let tolerance = 1e-9 * max(imageWidth, imageHeight)
    for (x, y) in corners {
      let dx = x - centerX
      let dy = y - centerY
      let rotatedX = centerX + dx * cosine - dy * sine
      let rotatedY = centerY + dx * sine + dy * cosine
      guard rotatedX >= -tolerance, rotatedY >= -tolerance,
        rotatedX <= imageWidth + tolerance, rotatedY <= imageHeight + tolerance
      else { return false }
    }
    return true
  }

  /// The crop shrunk about its own center until it holds only real pixels.
  ///
  /// Straightening turns the image under the rectangle, so raising the angle
  /// eventually pulls empty corners into a crop that was valid a moment ago.
  /// Shrinking about the center keeps the framing the user chose.
  public static func fitted(
    _ crop: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> CropRecipe {
    let crop = crop.clamped
    guard imageWidth > 0, imageHeight > 0 else { return crop }
    if isInsideStraightenedImage(crop, imageWidth: imageWidth, imageHeight: imageHeight) {
      return crop
    }

    let centerX = crop.centerX
    let centerY = crop.centerY
    let halfWidth = crop.unitWidth / 2
    let halfHeight = crop.unitHeight / 2

    func candidate(_ scale: Double) -> CropRecipe {
      var scaled = crop
      scaled.left = centerX - halfWidth * scale
      scaled.right = centerX + halfWidth * scale
      scaled.bottom = centerY - halfHeight * scale
      scaled.top = centerY + halfHeight * scale
      return scaled
    }

    var low = 0.0
    var high = 1.0
    for _ in 0..<fitIterations {
      let middle = (low + high) / 2
      if isInsideStraightenedImage(
        candidate(middle), imageWidth: imageWidth, imageHeight: imageHeight)
      {
        low = middle
      } else {
        high = middle
      }
    }
    return candidate(low)
  }

  /// The largest crop of the given aspect that fits the straightened image,
  /// centered on it.
  ///
  /// This is what the tool offers when the aspect lock changes, and what a
  /// straighten falls back to when the previous rectangle cannot survive the
  /// new angle.
  public static func maximumCrop(
    aspect: CropAspectRatio,
    angleDegrees: Double,
    imageWidth: Double,
    imageHeight: Double,
    overlay: CropOverlay = .thirds
  ) -> CropRecipe {
    guard imageWidth > 0, imageHeight > 0 else { return CropRecipe() }
    let angle = min(max(angleDegrees, -CropRecipe.maximumAngleDegrees), CropRecipe.maximumAngleDegrees)
    let cosine = abs(cos(angle * .pi / 180))
    let sine = abs(sin(angle * .pi / 180))

    // The largest w×h rectangle that fits inside a W×H rectangle turned by the
    // straighten angle, both centered, satisfies
    //     w·cos + h·sin ≤ W   and   w·sin + h·cos ≤ H.
    // With a locked ratio w = r·h the two bounds give h directly; free crops
    // take the ratio where both bounds are tight, which is the largest-area
    // rectangle.
    let ratio: Double
    if let locked = aspect.value(imageWidth: imageWidth, imageHeight: imageHeight), locked > 0 {
      ratio = locked
    } else {
      let numerator = imageWidth * cosine - imageHeight * sine
      let denominator = imageHeight * cosine - imageWidth * sine
      ratio =
        (numerator > 0 && denominator > 0)
        ? numerator / denominator
        : imageWidth / imageHeight
    }

    let widthBound = ratio * cosine + sine
    let heightBound = ratio * sine + cosine
    guard widthBound > 0, heightBound > 0 else { return CropRecipe() }
    let height = min(imageWidth / widthBound, imageHeight / heightBound)
    let width = ratio * height

    var crop = CropRecipe(
      left: (imageWidth - width) / 2 / imageWidth,
      bottom: (imageHeight - height) / 2 / imageHeight,
      right: (imageWidth + width) / 2 / imageWidth,
      top: (imageHeight + height) / 2 / imageHeight,
      angleDegrees: angle,
      aspectRatio: aspect,
      overlay: overlay
    )
    crop = crop.clamped
    // Rounding in unit space can push a boundary-tight rectangle a hair over
    // the edge. Fitting is a no-op when it is already inside.
    return fitted(crop, imageWidth: imageWidth, imageHeight: imageHeight)
  }

  // MARK: - Interaction

  /// The crop after a straighten angle change, kept legal.
  public static func settingAngle(
    _ angleDegrees: Double,
    on crop: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> CropRecipe {
    var updated = crop
    updated.angleDegrees = min(
      max(angleDegrees, -CropRecipe.maximumAngleDegrees), CropRecipe.maximumAngleDegrees)
    updated = updated.clamped
    return fitted(updated, imageWidth: imageWidth, imageHeight: imageHeight)
  }

  /// The crop after the aspect lock changes.
  ///
  /// A newly locked ratio keeps the rectangle's center and area where it can,
  /// so choosing 1:1 tightens the existing framing instead of jumping to the
  /// whole frame.
  public static func settingAspect(
    _ aspect: CropAspectRatio,
    on crop: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> CropRecipe {
    var updated = crop
    updated.aspectRatio = aspect
    guard let unitRatio = unitAspect(aspect, imageWidth: imageWidth, imageHeight: imageHeight)
    else {
      // Free: the rectangle it already has is legal.
      return fitted(updated.clamped, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    let centerX = crop.centerX
    let centerY = crop.centerY
    // Keep the area, so the lock reshapes the crop rather than resizing it.
    let area = max(crop.unitWidth * crop.unitHeight, .leastNonzeroMagnitude)
    var height = (area / unitRatio).squareRoot()
    var width = unitRatio * height
    // Never leave the frame: shrink both axes together so the lock survives.
    if width > 1 || height > 1 {
      let scale = min(
        1 / max(width, .leastNonzeroMagnitude),
        1 / max(height, .leastNonzeroMagnitude)
      )
      width *= scale
      height *= scale
    }

    updated.left = centerX - width / 2
    updated.right = centerX + width / 2
    updated.bottom = centerY - height / 2
    updated.top = centerY + height / 2
    updated = slid(updated, intoUnitFrame: true)
    return fitted(updated, imageWidth: imageWidth, imageHeight: imageHeight)
  }

  /// The crop after dragging one handle to a unit position.
  public static func resized(
    _ crop: CropRecipe,
    handle: CropHandle,
    toUnitX unitX: Double,
    unitY: Double,
    imageWidth: Double,
    imageHeight: Double
  ) -> CropRecipe {
    var updated = crop
    let minimum = CropRecipe.minimumUnitSize
    let x = min(max(unitX, 0), 1)
    let y = min(max(unitY, 0), 1)

    if handle.movesLeftEdge { updated.left = min(x, crop.right - minimum) }
    if handle.movesRightEdge { updated.right = max(x, crop.left + minimum) }
    if handle.movesBottomEdge { updated.bottom = min(y, crop.top - minimum) }
    if handle.movesTopEdge { updated.top = max(y, crop.bottom + minimum) }

    if let unitRatio = unitAspect(
      crop.aspectRatio, imageWidth: imageWidth, imageHeight: imageHeight)
    {
      updated = enforcingAspect(unitRatio, on: updated, handle: handle)
    }
    updated = updated.clamped
    return fitted(updated, imageWidth: imageWidth, imageHeight: imageHeight)
  }

  /// The crop moved across the image, staying whole.
  ///
  /// A drag that would push the rectangle out of the frame stops at the edge
  /// rather than shrinking it, which is what a crop tool's box does.
  public static func moved(
    _ crop: CropRecipe,
    byUnitX deltaX: Double,
    unitY deltaY: Double,
    imageWidth: Double,
    imageHeight: Double
  ) -> CropRecipe {
    var updated = crop
    updated.left += deltaX
    updated.right += deltaX
    updated.bottom += deltaY
    updated.top += deltaY
    updated = slid(updated, intoUnitFrame: true)

    guard crop.angleDegrees != 0 else { return updated }
    // With a straighten in play the frame is not the limit; the turned image
    // is. Step the move back toward where it started until it is legal again,
    // so a drag slides along the edge instead of stopping dead.
    if isInsideStraightenedImage(updated, imageWidth: imageWidth, imageHeight: imageHeight) {
      return updated
    }
    var low = 0.0
    var high = 1.0
    for _ in 0..<fitIterations {
      let middle = (low + high) / 2
      var candidate = crop
      candidate.left += deltaX * middle
      candidate.right += deltaX * middle
      candidate.bottom += deltaY * middle
      candidate.top += deltaY * middle
      candidate = slid(candidate, intoUnitFrame: true)
      if isInsideStraightenedImage(candidate, imageWidth: imageWidth, imageHeight: imageHeight) {
        low = middle
      } else {
        high = middle
      }
    }
    var result = crop
    result.left += deltaX * low
    result.right += deltaX * low
    result.bottom += deltaY * low
    result.top += deltaY * low
    return slid(result, intoUnitFrame: true)
  }

  /// A new crop drawn from one corner to the current pointer.
  ///
  /// The supplied recipe contributes the current aspect, straighten and guide
  /// settings. Building the small seed rectangle on the pointer's side of the
  /// anchor lets the existing resize path enforce minimum size, aspect locking
  /// and straightened-image bounds without a second geometry implementation.
  public static func created(
    fromUnitX startX: Double,
    unitY startY: Double,
    toUnitX endX: Double,
    unitY endY: Double,
    like recipe: CropRecipe,
    imageWidth: Double,
    imageHeight: Double
  ) -> CropRecipe {
    let minimum = CropRecipe.minimumUnitSize
    let startX = min(max(startX, 0), 1)
    let startY = min(max(startY, 0), 1)
    let endX = min(max(endX, 0), 1)
    let endY = min(max(endY, 0), 1)
    let movesRight = endX >= startX
    let movesTop = endY >= startY

    var seed = recipe
    if movesRight {
      seed.left = min(startX, 1 - minimum)
      seed.right = seed.left + minimum
    } else {
      seed.right = max(startX, minimum)
      seed.left = seed.right - minimum
    }
    if movesTop {
      seed.bottom = min(startY, 1 - minimum)
      seed.top = seed.bottom + minimum
    } else {
      seed.top = max(startY, minimum)
      seed.bottom = seed.top - minimum
    }

    let handle: CropHandle =
      switch (movesRight, movesTop) {
      case (true, true): .topRight
      case (true, false): .bottomRight
      case (false, true): .topLeft
      case (false, false): .bottomLeft
      }
    return resized(
      seed,
      handle: handle,
      toUnitX: endX,
      unitY: endY,
      imageWidth: imageWidth,
      imageHeight: imageHeight
    )
  }

  /// Which handle a unit point is grabbing, within a unit tolerance.
  ///
  /// Corners win over edges, so the corner of a small crop stays reachable.
  public static func handle(
    at unitX: Double,
    unitY: Double,
    in crop: CropRecipe,
    toleranceX: Double,
    toleranceY: Double
  ) -> CropHandle? {
    let corners: [CropHandle] = [.bottomLeft, .bottomRight, .topLeft, .topRight]
    let edges: [CropHandle] = [.left, .right, .bottom, .top]
    for handle in corners + edges {
      let position = handle.position(in: crop)
      let withinX: Bool
      let withinY: Bool
      switch handle {
      case .left, .right:
        withinX = abs(unitX - position.x) <= toleranceX
        withinY = unitY >= crop.bottom - toleranceY && unitY <= crop.top + toleranceY
      case .bottom, .top:
        withinX = unitX >= crop.left - toleranceX && unitX <= crop.right + toleranceX
        withinY = abs(unitY - position.y) <= toleranceY
      default:
        withinX = abs(unitX - position.x) <= toleranceX
        withinY = abs(unitY - position.y) <= toleranceY
      }
      if withinX && withinY { return handle }
    }
    return nil
  }

  // MARK: - Private

  /// Restores the locked ratio after one edge moved, growing or shrinking the
  /// other axis away from whichever edge the drag is holding still.
  private static func enforcingAspect(
    _ unitRatio: Double,
    on crop: CropRecipe,
    handle: CropHandle
  ) -> CropRecipe {
    var updated = crop
    let minimum = CropRecipe.minimumUnitSize

    switch handle {
    case .left, .right:
      // A vertical edge sets the width; height follows, centered.
      let anchorX = handle.movesLeftEdge ? updated.right : updated.left
      let centerY = crop.centerY
      var width = max(updated.unitWidth, minimum, minimum * unitRatio)
      var height = width / unitRatio
      let maximumWidth = handle.movesLeftEdge ? anchorX : 1 - anchorX
      let maximumHeight = 2 * min(centerY, 1 - centerY)
      let scale = min(1, maximumWidth / width, maximumHeight / height)
      width *= scale
      height *= scale
      if handle.movesLeftEdge {
        updated.left = anchorX - width
        updated.right = anchorX
      } else {
        updated.left = anchorX
        updated.right = anchorX + width
      }
      updated.bottom = centerY - height / 2
      updated.top = centerY + height / 2
    case .bottom, .top:
      let anchorY = handle.movesBottomEdge ? updated.top : updated.bottom
      let centerX = crop.centerX
      var height = max(updated.unitHeight, minimum, minimum / unitRatio)
      var width = height * unitRatio
      let maximumWidth = 2 * min(centerX, 1 - centerX)
      let maximumHeight = handle.movesBottomEdge ? anchorY : 1 - anchorY
      let scale = min(1, maximumWidth / width, maximumHeight / height)
      width *= scale
      height *= scale
      updated.left = centerX - width / 2
      updated.right = centerX + width / 2
      if handle.movesBottomEdge {
        updated.bottom = anchorY - height
        updated.top = anchorY
      } else {
        updated.bottom = anchorY
        updated.top = anchorY + height
      }
    default:
      // A corner drag pins the opposite corner and takes the larger of the two
      // proposed dimensions, so the box tracks the pointer on both axes.
      let anchorX = handle.movesLeftEdge ? updated.right : updated.left
      let anchorY = handle.movesBottomEdge ? updated.top : updated.bottom
      let width = max(updated.unitWidth, minimum)
      let height = max(updated.unitHeight, minimum)
      var resolvedWidth = max(width, height * unitRatio, minimum * unitRatio)
      var resolvedHeight = resolvedWidth / unitRatio
      let maximumWidth = handle.movesLeftEdge ? anchorX : 1 - anchorX
      let maximumHeight = handle.movesBottomEdge ? anchorY : 1 - anchorY
      let scale = min(1, maximumWidth / resolvedWidth, maximumHeight / resolvedHeight)
      resolvedWidth *= scale
      resolvedHeight *= scale
      if handle.movesLeftEdge {
        updated.left = anchorX - resolvedWidth
        updated.right = anchorX
      } else {
        updated.left = anchorX
        updated.right = anchorX + resolvedWidth
      }
      if handle.movesBottomEdge {
        updated.bottom = anchorY - resolvedHeight
        updated.top = anchorY
      } else {
        updated.bottom = anchorY
        updated.top = anchorY + resolvedHeight
      }
    }
    return updated
  }

  /// Slides a rectangle back inside the unit frame without changing its size.
  private static func slid(_ crop: CropRecipe, intoUnitFrame: Bool) -> CropRecipe {
    guard intoUnitFrame else { return crop }
    var updated = crop
    let width = min(updated.unitWidth, 1)
    let height = min(updated.unitHeight, 1)
    if updated.left < 0 {
      updated.left = 0
      updated.right = width
    }
    if updated.right > 1 {
      updated.right = 1
      updated.left = 1 - width
    }
    if updated.bottom < 0 {
      updated.bottom = 0
      updated.top = height
    }
    if updated.top > 1 {
      updated.top = 1
      updated.bottom = 1 - height
    }
    return updated.clamped
  }
}

extension CropRecipe {
  /// The same straighten, aspect lock and overlay over the whole frame.
  ///
  /// The crop tool renders this while it is open: the image turns inside its
  /// original frame so the whole picture stays visible, and the rectangle the
  /// user is dragging is drawn over it rather than cut out of it. Committing
  /// the tool replaces it with the real crop.
  public var openedToFullFrame: CropRecipe {
    CropRecipe(
      left: 0,
      bottom: 0,
      right: 1,
      top: 1,
      angleDegrees: angleDegrees,
      aspectRatio: aspectRatio,
      overlay: overlay
    )
  }
}
