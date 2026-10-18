import AppKit
import CoreText
import CryptoKit
import Foundation

/// CPU preparation for GPU Program's system-font outline buffer. All offsets in
/// the buffer are float4 indices; glyph coordinates are normalized by font size.
enum PipelineSystemFont {
  struct Prepared {
    let bytes: Data
    let fingerprint: String
    let resolvedName: String
  }

  static func prepare(design: String, weight: String, strings: [String]) throws -> Prepared {
    let fontSize: CGFloat = 24
    let fontWeight: NSFont.Weight = switch weight {
    case "regular": .regular
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    default: throw invalid("unsupported weight")
    }
    let systemFont: NSFont = switch design {
    case "system": .systemFont(ofSize: fontSize, weight: fontWeight)
    case "monospaced": .monospacedSystemFont(ofSize: fontSize, weight: fontWeight)
    case "monospacedDigits": .monospacedDigitSystemFont(ofSize: fontSize, weight: fontWeight)
    default: throw invalid("unsupported design")
    }
    let resolvedName = systemFont.fontName
    let font = CTFontCreateWithName(resolvedName as CFString, fontSize, nil)
    let actualName = CTFontCopyPostScriptName(font) as String
    guard actualName == resolvedName else { throw invalid("system font resolution changed") }
    let divisor = Float(fontSize)
    let ascent = Float(CTFontGetAscent(font)) / divisor
    let descent = Float(CTFontGetDescent(font)) / divisor

    var glyphIDs: [CGGlyph] = []
    var glyphIndex: [CGGlyph: Int] = [:]
    var runs: [SIMD4<Float>] = []
    var placements: [SIMD4<Float>] = []
    for string in strings {
      let attributed = NSAttributedString(string: string,
        attributes: [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font])
      let line = CTLineCreateWithAttributedString(attributed)
      let start = placements.count
      for item in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(item) as NSDictionary
        guard let value = attributes[kCTFontAttributeName] else {
          throw invalid("a label has no font")
        }
        let runFont = value as! CTFont
        guard (CTFontCopyPostScriptName(runFont) as String) == actualName else {
          throw invalid("a label needs a font fallback")
        }
        let count = CTRunGetGlyphCount(item)
        var runGlyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(item, CFRangeMake(0, 0), &runGlyphs)
        CTRunGetPositions(item, CFRangeMake(0, 0), &positions)
        for (glyph, point) in zip(runGlyphs, positions) {
          let index: Int
          if let existing = glyphIndex[glyph] { index = existing }
          else {
            index = glyphIDs.count
            glyphIndex[glyph] = index
            glyphIDs.append(glyph)
          }
          placements.append(SIMD4(Float(index), Float(point.x) / divisor,
            Float(point.y) / divisor, 0))
        }
      }
      runs.append(SIMD4(Float(start), Float(placements.count - start),
        Float(CTLineGetTypographicBounds(line, nil, nil, nil)) / divisor, 0))
    }

    var glyphs: [SIMD4<Float>] = []
    var segments: [SIMD4<Float>] = []
    for glyph in glyphIDs {
      var advance = CGSize.zero
      var mutableGlyph = glyph
      CTFontGetAdvancesForGlyphs(font, .horizontal, &mutableGlyph, &advance, 1)
      let start = segments.count
      let path = CTFontCreatePathForGlyph(font, glyph, nil)
      if let path {
        var current = CGPoint.zero
        var contourStart = CGPoint.zero
        var hasContour = false
        func append(_ a: CGPoint, _ b: CGPoint) {
          let ax = Float(a.x) / divisor
          let ay = Float(a.y) / divisor
          let bx = Float(b.x) / divisor
          let by = Float(b.y) / divisor
          if abs(ax - bx) + abs(ay - by) > 0.000001 {
            segments.append(SIMD4(ax, ay, bx, by))
          }
        }
        func quadratic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ depth: Int) {
          let dx = Float(c.x - a.x), dy = Float(c.y - a.y)
          let error = abs(Float(b.x - a.x) * dy - Float(b.y - a.y) * dx)
            / max(hypot(dx, dy), 1)
          if error <= 0.12 || depth >= 10 { append(a, c); return }
          let ab = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
          let bc = CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2)
          let middle = CGPoint(x: (ab.x + bc.x) / 2, y: (ab.y + bc.y) / 2)
          quadratic(a, ab, middle, depth + 1)
          quadratic(middle, bc, c, depth + 1)
        }
        func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint,
          _ depth: Int) {
          let chord = max(hypot(d.x - a.x, d.y - a.y), 1)
          let e1 = abs((b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x)) / chord
          let e2 = abs((c.x - a.x) * (d.y - a.y) - (c.y - a.y) * (d.x - a.x)) / chord
          if max(e1, e2) <= 0.12 || depth >= 10 { append(a, d); return }
          let ab = midpoint(a, b), bc = midpoint(b, c), cd = midpoint(c, d)
          let abc = midpoint(ab, bc), bcd = midpoint(bc, cd)
          let middle = midpoint(abc, bcd)
          cubic(a, ab, abc, middle, depth + 1)
          cubic(middle, bcd, cd, d, depth + 1)
        }
        path.applyWithBlock { pointer in
          let element = pointer.pointee
          switch element.type {
          case .moveToPoint:
            if hasContour { append(current, contourStart) }
            contourStart = element.points[0]
            current = contourStart
            hasContour = true
          case .addLineToPoint:
            let next = element.points[0]
            append(current, next)
            current = next
          case .addQuadCurveToPoint:
            let next = element.points[1]
            quadratic(current, element.points[0], next, 0)
            current = next
          case .addCurveToPoint:
            let next = element.points[2]
            cubic(current, element.points[0], element.points[1], next, 0)
            current = next
          case .closeSubpath:
            append(current, contourStart)
            current = contourStart
            hasContour = false
          @unknown default: break
          }
        }
        if hasContour { append(current, contourStart) }
      }
      let box = path?.boundingBoxOfPath ?? .zero
      glyphs.append(SIMD4(Float(start), Float(segments.count - start),
        Float(box.minX) / divisor, Float(box.minY) / divisor))
      glyphs.append(SIMD4(Float(box.maxX) / divisor, Float(box.maxY) / divisor,
        Float(advance.width) / divisor, 0))
    }
    guard glyphs.count <= 512, segments.count <= 32_768,
      placements.count <= 512 else { throw invalid("font outline limits exceeded") }
    let glyphStart = 3
    let runStart = glyphStart + glyphs.count
    let placementStart = runStart + runs.count
    let segmentStart = placementStart + placements.count
    let header: [SIMD4<Float>] = [
      SIMD4(Float(glyphStart), Float(runStart), Float(placementStart), Float(segmentStart)),
      SIMD4(Float(glyphIDs.count), Float(runs.count), Float(placements.count),
        Float(segments.count)),
      SIMD4(ascent, descent, 0, 0),
    ]
    let words = header + glyphs + runs + placements + segments
    let bytes = words.withUnsafeBytes { Data($0) }
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return Prepared(bytes: bytes, fingerprint: "\(actualName):\(digest)",
      resolvedName: actualName)
  }

  private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
  }

  private static func invalid(_ detail: String) -> PipelineEngineError {
    .invalidInvocation("GPU Program system font: \(detail).")
  }
}
