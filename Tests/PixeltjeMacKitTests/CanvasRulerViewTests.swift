import CoreGraphics
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func rotatedVerticalRulerLabelStaysInsideItsLeftEdge() {
  let textSize = CGSize(width: 24, height: 9)
  let origin = CanvasRulerView.verticalLabelOrigin(for: textSize, at: 100)

  // After a positive 90-degree rotation, the text height extends left from
  // the transformed origin. Its lower edge should retain the two-point inset.
  #expect(origin.x - textSize.height == 2)
  #expect(origin.y == 102)
}
