import Foundation

/// Deterministic, top-down crop of the previous frame around a planned destination.
/// It never analyzes generated pixels; the prior text plan supplies the region size.
public enum PipelineNavigationCrop {
  public static func make(
    image: PipelineImageInput,
    plan: PipelineScenePlan,
    x: Double,
    y: Double,
    size: Int = 1024,
    margin: Double = 1.5
  ) throws -> PipelineImageInput {
    guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
      (256...2048).contains(size), margin.isFinite, (1...3).contains(margin)
    else {
      throw PipelineEngineError.invalidInvocation("Invalid navigation crop coordinates or size.")
    }
    let box = plan.region(atX: x, y: y)?.box
    let boxSide = box.map { max($0[2] - $0[0], $0[3] - $0[1]) } ?? 0.4
    let side = min(max(boxSide * margin, 0.2), 0.75)
    let left = min(max(x - side / 2, 0), 1 - side)
    let top = min(max(y - side / 2, 0), 1 - side)
    var rgba = [Float](repeating: 0, count: size * size * 4)

    for row in 0..<size {
      if row.isMultiple(of: 64) { try Task.checkCancellation() }
      let sourceY = (top + (Double(row) + 0.5) / Double(size) * side)
        * Double(image.height) - 0.5
      let y0 = min(max(Int(floor(sourceY)), 0), image.height - 1)
      let y1 = min(y0 + 1, image.height - 1)
      let fy = Float(min(max(sourceY - Double(y0), 0), 1))
      for column in 0..<size {
        let sourceX = (left + (Double(column) + 0.5) / Double(size) * side)
          * Double(image.width) - 0.5
        let x0 = min(max(Int(floor(sourceX)), 0), image.width - 1)
        let x1 = min(x0 + 1, image.width - 1)
        let fx = Float(min(max(sourceX - Double(x0), 0), 1))
        let output = (row * size + column) * 4
        let a = (y0 * image.width + x0) * 4
        let b = (y0 * image.width + x1) * 4
        let c = (y1 * image.width + x0) * 4
        let d = (y1 * image.width + x1) * 4
        for channel in 0..<4 {
          let topValue = image.rgba[a + channel]
            + (image.rgba[b + channel] - image.rgba[a + channel]) * fx
          let bottomValue = image.rgba[c + channel]
            + (image.rgba[d + channel] - image.rgba[c + channel]) * fx
          rgba[output + channel] = topValue + (bottomValue - topValue) * fy
        }
      }
    }
    return try PipelineImageInput(width: size, height: size, rgba: rgba)
  }
}
