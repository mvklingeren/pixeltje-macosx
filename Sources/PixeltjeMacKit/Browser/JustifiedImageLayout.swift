import AppKit

struct JustifiedGeometry {
  var itemFrames: [CGRect]
  var contentHeight: CGFloat
}

enum JustifiedRowSolver {
  static func solve(
    aspectRatios: [CGFloat],
    width: CGFloat,
    preferredHeight: CGFloat,
    spacing: CGFloat,
    insets: NSEdgeInsets
  ) -> JustifiedGeometry {
    let usableWidth = width - insets.left - insets.right
    guard usableWidth > 0, !aspectRatios.isEmpty else {
      return JustifiedGeometry(itemFrames: [], contentHeight: 0)
    }

    let ratios = aspectRatios.map { min(max($0.isFinite ? $0 : 1.5, 0.25), 4) }
    var frames = Array(repeating: CGRect.zero, count: ratios.count)
    var rowStart = 0
    var rowRatio: CGFloat = 0
    var y = insets.top

    func placeRow(endingAt end: Int, fillsWidth: Bool) -> CGFloat {
      let count = end - rowStart
      let gapWidth = CGFloat(max(count - 1, 0)) * spacing
      let imageWidth = max(usableWidth - gapWidth, 1)
      let height = fillsWidth ? imageWidth / max(rowRatio, 0.01) : preferredHeight
      var x = insets.left
      for index in rowStart..<end {
        let isLast = index == end - 1
        let itemWidth =
          fillsWidth && isLast
          ? max(insets.left + usableWidth - x, 1)
          : (ratios[index] * height).rounded()
        frames[index] = CGRect(
          x: x,
          y: y,
          width: itemWidth,
          height: height.rounded()
        )
        x += itemWidth + spacing
      }
      return height.rounded()
    }

    for index in ratios.indices {
      rowRatio += ratios[index]
      let itemCount = index - rowStart + 1
      let proposedWidth = rowRatio * preferredHeight + CGFloat(itemCount - 1) * spacing
      if proposedWidth >= usableWidth {
        y += placeRow(endingAt: index + 1, fillsWidth: true) + spacing
        rowStart = index + 1
        rowRatio = 0
      }
    }

    if rowStart < ratios.count {
      y += placeRow(endingAt: ratios.count, fillsWidth: false) + spacing
    }
    let contentHeight = max(y - spacing + insets.bottom, 0)
    return JustifiedGeometry(itemFrames: frames, contentHeight: contentHeight)
  }
}

@MainActor
protocol JustifiedImageLayoutDataSource: AnyObject {
  func imageLayoutAspectRatio(at index: Int) -> CGFloat?
}

final class JustifiedImageLayout: NSCollectionViewLayout {
  weak var dataSource: JustifiedImageLayoutDataSource?

  var preferredRowHeight: CGFloat = 200 {
    didSet { if preferredRowHeight != oldValue { invalidateLayout() } }
  }
  var spacing: CGFloat = 10 {
    didSet { if spacing != oldValue { invalidateLayout() } }
  }
  var insets = NSEdgeInsets(top: 10, left: 10, bottom: 18, right: 10) {
    didSet { invalidateLayout() }
  }

  private var itemAttributes: [NSCollectionViewLayoutAttributes] = []
  private var calculatedContentSize = NSSize.zero

  override var collectionViewContentSize: NSSize { calculatedContentSize }

  override func prepare() {
    super.prepare()
    guard let collectionView, collectionView.numberOfSections > 0 else {
      itemAttributes = []
      calculatedContentSize = .zero
      return
    }

    let count = collectionView.numberOfItems(inSection: 0)
    let ratios = (0..<count).map { dataSource?.imageLayoutAspectRatio(at: $0) ?? 1.5 }
    let geometry = JustifiedRowSolver.solve(
      aspectRatios: ratios,
      width: collectionView.bounds.width,
      preferredHeight: preferredRowHeight,
      spacing: spacing,
      insets: insets
    )
    itemAttributes = geometry.itemFrames.enumerated().map { index, frame in
      let attributes = NSCollectionViewLayoutAttributes(
        forItemWith: IndexPath(item: index, section: 0))
      attributes.frame = frame
      return attributes
    }
    calculatedContentSize = NSSize(
      width: collectionView.bounds.width,
      height: geometry.contentHeight
    )
  }

  override func layoutAttributesForElements(
    in rect: NSRect
  ) -> [NSCollectionViewLayoutAttributes] {
    itemAttributes.filter { $0.frame.intersects(rect) }
  }

  override func layoutAttributesForItem(
    at indexPath: IndexPath
  ) -> NSCollectionViewLayoutAttributes? {
    guard indexPath.section == 0, itemAttributes.indices.contains(indexPath.item) else {
      return nil
    }
    return itemAttributes[indexPath.item]
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
    collectionView?.bounds.width != newBounds.width
  }
}
