import AppKit
import PixeltjePipelineDomain

enum PipelineNodeArrangement: CaseIterable {
  case smartFlow
  case leftToRight
  case topToBottom
  case grid

  var title: String {
    switch self {
    case .smartFlow: "Smart Flow"
    case .leftToRight: "Left to Right"
    case .topToBottom: "Top to Bottom"
    case .grid: "Compact Grid"
    }
  }
}

/// Calculates editor-only positions without changing graph nodes or connections.
struct PipelineGraphLayout {
  static func bounds(in document: PipelineDocument) -> CGRect? {
    guard !document.nodes.isEmpty else { return nil }
    return document.nodes.enumerated().reduce(CGRect.null) { bounds, entry in
      let (index, node) = entry
      let origin = document.presentation?.nodePositions[node.id.rawValue]
        ?? fallbackPosition(index)
      let size = PipelineGraphMetrics.size(for: node, in: document)
      return bounds.union(CGRect(x: origin.x, y: origin.y,
        width: size.width, height: size.height))
    }
  }

  static func positions(
    in document: PipelineDocument,
    arrangement: PipelineNodeArrangement,
    origin: PipelinePoint
  ) -> [String: PipelinePoint] {
    let nodes = document.nodes
    guard !nodes.isEmpty else { return [:] }

    let sizes = Dictionary(uniqueKeysWithValues: nodes.map { node in
      (node.id, PipelineGraphMetrics.size(for: node, in: document))
    })
    let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
    let positions = document.presentation?.nodePositions ?? [:]
    let orderedIDs = nodes.map(\.id).sorted { first, second in
      let firstIndex = indices[first] ?? 0
      let secondIndex = indices[second] ?? 0
      let firstPoint = positions[first.rawValue] ?? fallbackPosition(firstIndex)
      let secondPoint = positions[second.rawValue] ?? fallbackPosition(secondIndex)
      if firstPoint.y != secondPoint.y { return firstPoint.y < secondPoint.y }
      if firstPoint.x != secondPoint.x { return firstPoint.x < secondPoint.x }
      return firstIndex < secondIndex
    }
    let order = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map {
      ($0.element, $0.offset)
    })
    let start = PipelinePoint(x: max(20, origin.x), y: max(20, origin.y))

    if arrangement == .grid {
      return gridPositions(for: orderedIDs, sizes: sizes, origin: start)
    }

    let validIDs = Set(orderedIDs)
    let edges = (document.connections + document.controlConnections).compactMap { connection
      -> (PipelineNodeID, PipelineNodeID)? in
      let source = connection.output.nodeID
      let destination = connection.input.nodeID
      guard source != destination, validIDs.contains(source), validIDs.contains(destination)
      else { return nil }
      return (source, destination)
    }
    var neighbors: [PipelineNodeID: Set<PipelineNodeID>] = [:]
    var predecessors: [PipelineNodeID: Set<PipelineNodeID>] = [:]
    var successors: [PipelineNodeID: Set<PipelineNodeID>] = [:]
    for (source, destination) in edges {
      neighbors[source, default: []].insert(destination)
      neighbors[destination, default: []].insert(source)
      predecessors[destination, default: []].insert(source)
      successors[source, default: []].insert(destination)
    }

    var remaining = validIDs
    var result: [String: PipelinePoint] = [:]
    var componentY = start.y
    for first in orderedIDs where remaining.contains(first) {
      var component: Set<PipelineNodeID> = []
      var queue = [first]
      remaining.remove(first)
      while let current = queue.popLast() {
        component.insert(current)
        for neighbor in neighbors[current, default: []] where remaining.remove(neighbor) != nil {
          queue.append(neighbor)
        }
      }

      // Break cycles at the earliest saved card position. All remaining edges
      // still contribute to the component, and the result is deterministic.
      var unranked = component
      var ranks: [PipelineNodeID: Int] = [:]
      while !unranked.isEmpty {
        let ready = unranked.filter { id in
          predecessors[id, default: []].isDisjoint(with: unranked)
        }
        let next = (ready.isEmpty ? unranked : ready).min {
          (order[$0] ?? 0) < (order[$1] ?? 0)
        }!
        ranks[next] = (predecessors[next, default: []]
          .compactMap { ranks[$0] }.max() ?? -1) + 1
        unranked.remove(next)
      }

      let maximumRank = ranks.values.max() ?? 0
      var columns = (0...maximumRank).map { rank in
        orderedIDs.filter { component.contains($0) && ranks[$0] == rank }
      }
      if arrangement == .smartFlow {
        minimizeCrossings(in: &columns, ranks: ranks,
          predecessors: predecessors, successors: successors)
      }
      let columnHeights = columns.map { column in
        max(0, column.reduce(CGFloat.zero) { height, id in
          height + (sizes[id]?.height ?? 0) + 40
        } - 40)
      }
      let balancedHeight = columnHeights.max() ?? 0
      var primaryOffset: CGFloat = 0
      var componentHeight: CGFloat = 0
      for rank in 0...maximumRank {
        let rankIDs = columns[rank]
        var secondaryOffset: CGFloat = 0
        var largestPrimary: CGFloat = 0
        for id in rankIDs {
          guard let size = sizes[id] else { continue }
          let point: PipelinePoint
          switch arrangement {
          case .smartFlow, .leftToRight:
            point = PipelinePoint(
              x: start.x + Double(primaryOffset),
              y: componentY + Double(secondaryOffset)
                + (arrangement == .smartFlow
                  ? Double((balancedHeight - columnHeights[rank]) / 2) : 0))
            largestPrimary = max(largestPrimary, size.width)
            secondaryOffset += size.height + 40
          case .topToBottom:
            point = PipelinePoint(
              x: start.x + Double(secondaryOffset),
              y: componentY + Double(primaryOffset))
            largestPrimary = max(largestPrimary, size.height)
            secondaryOffset += size.width + 40
          case .grid: continue
          }
          result[id.rawValue] = point
        }
        if arrangement == .leftToRight || arrangement == .smartFlow {
          componentHeight = max(componentHeight, max(0, secondaryOffset - 40))
        } else {
          componentHeight = max(componentHeight, primaryOffset + largestPrimary)
        }
        primaryOffset += largestPrimary + 80
      }
      componentY += Double(componentHeight + 100)
    }
    return result
  }

  private static func minimizeCrossings(
    in columns: inout [[PipelineNodeID]],
    ranks: [PipelineNodeID: Int],
    predecessors: [PipelineNodeID: Set<PipelineNodeID>],
    successors: [PipelineNodeID: Set<PipelineNodeID>]
  ) {
    guard columns.count > 1 else { return }
    // Alternating barycenter sweeps pull related branches together while
    // retaining the saved spatial order for nodes with no useful neighbor.
    for _ in 0..<3 {
      for rank in 1..<columns.count {
        let updated = reordered(columns[rank], rank: rank, columns: columns,
          ranks: ranks, adjacent: predecessors, towardEarlierRanks: true)
        columns[rank] = updated
      }
      for rank in stride(from: columns.count - 2, through: 0, by: -1) {
        let updated = reordered(columns[rank], rank: rank, columns: columns,
          ranks: ranks, adjacent: successors, towardEarlierRanks: false)
        columns[rank] = updated
      }
    }
  }

  private static func reordered(
    _ ids: [PipelineNodeID],
    rank: Int,
    columns: [[PipelineNodeID]],
    ranks: [PipelineNodeID: Int],
    adjacent: [PipelineNodeID: Set<PipelineNodeID>],
    towardEarlierRanks: Bool
  ) -> [PipelineNodeID] {
    let currentIndices = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
      ($0.element, $0.offset)
    })
    func barycenter(_ id: PipelineNodeID) -> Double {
      let neighbors = adjacent[id, default: []].compactMap { neighbor -> Double? in
        guard let neighborRank = ranks[neighbor],
          towardEarlierRanks ? neighborRank < rank : neighborRank > rank,
          let index = columns[neighborRank].firstIndex(of: neighbor)
        else { return nil }
        return Double(index + 1) / Double(columns[neighborRank].count + 1)
      }.sorted()
      return neighbors.isEmpty
        ? Double((currentIndices[id] ?? 0) + 1) / Double(ids.count + 1)
        : neighbors.reduce(0, +) / Double(neighbors.count)
    }
    let scores = Dictionary(uniqueKeysWithValues: ids.map { ($0, barycenter($0)) })
    return ids.sorted { first, second in
      if scores[first] != scores[second] {
        return (scores[first] ?? 0) < (scores[second] ?? 0)
      }
      return (currentIndices[first] ?? 0) < (currentIndices[second] ?? 0)
    }
  }

  private static func gridPositions(
    for ids: [PipelineNodeID],
    sizes: [PipelineNodeID: CGSize],
    origin: PipelinePoint
  ) -> [String: PipelinePoint] {
    let columnCount = min(5, max(2, Int(ceil(sqrt(Double(ids.count))))))
    var result: [String: PipelinePoint] = [:]
    var y = origin.y
    for rowStart in stride(from: 0, to: ids.count, by: columnCount) {
      let row = ids[rowStart..<min(rowStart + columnCount, ids.count)]
      var x = origin.x
      var rowHeight: CGFloat = 0
      for id in row {
        guard let size = sizes[id] else { continue }
        result[id.rawValue] = PipelinePoint(x: x, y: y)
        x += Double(size.width + 40)
        rowHeight = max(rowHeight, size.height)
      }
      y += Double(rowHeight + 40)
    }
    return result
  }

  private static func fallbackPosition(_ index: Int) -> PipelinePoint {
    PipelinePoint(x: 100 + Double(index % 4) * 270,
      y: 100 + Double(index / 4) * 180)
  }
}
