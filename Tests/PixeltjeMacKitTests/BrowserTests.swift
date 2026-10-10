import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import PixeltjeMacKit

@Test func scannerClassifiesRawBeforeGenericImages() {
  let rawType = UTType("public.camera-raw-image")!
  #expect(ImageFolderScanner.kind(for: rawType, pathExtension: "") == .cameraRaw)
  #expect(ImageFolderScanner.kind(for: .jpeg, pathExtension: "") == .coreImage)
  #expect(ImageFolderScanner.kind(for: .plainText, pathExtension: "") == nil)
}

@Test func scannerUsesNaturalOrderAndHonorsRecursion() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("PixeltjeMacBrowserTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  try Data().write(to: root.appendingPathComponent("photo10.jpg"))
  try Data().write(to: root.appendingPathComponent("photo2.png"))
  try Data().write(to: root.appendingPathComponent("notes.txt"))
  try Data().write(to: root.appendingPathComponent(".hidden.jpg"))
  let nested = root.appendingPathComponent("nested", isDirectory: true)
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
  try Data().write(to: nested.appendingPathComponent("photo1.heic"))

  let flat = ImageFolderScanner.files(in: root, recursively: false)
  #expect(flat.map(\.relativePath) == ["photo2.png", "photo10.jpg"])

  let recursive = ImageFolderScanner.files(in: root, recursively: true)
  #expect(
    recursive.map(\.relativePath) == [
      "nested/photo1.heic",
      "photo2.png",
      "photo10.jpg",
    ])
}

@Test func justifiedRowsFillTheAvailableWidthWithoutCropping() {
  let geometry = JustifiedRowSolver.solve(
    aspectRatios: [1, 1],
    width: 210,
    preferredHeight: 100,
    spacing: 10,
    insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  )

  #expect(geometry.itemFrames.count == 2)
  #expect(geometry.itemFrames[0] == CGRect(x: 0, y: 0, width: 100, height: 100))
  #expect(geometry.itemFrames[1] == CGRect(x: 110, y: 0, width: 100, height: 100))
  #expect(geometry.contentHeight == 100)
}

@Test func finalJustifiedRowKeepsThePreferredHeight() {
  let geometry = JustifiedRowSolver.solve(
    aspectRatios: [1.5],
    width: 500,
    preferredHeight: 100,
    spacing: 10,
    insets: NSEdgeInsets(top: 8, left: 8, bottom: 12, right: 8)
  )

  #expect(geometry.itemFrames == [CGRect(x: 8, y: 8, width: 150, height: 100)])
  #expect(geometry.contentHeight == 120)
}

@Test func browserFullscreenNavigationUsesTheExpectedSteps() {
  #expect(BrowserPreviewNavigation.previous.offset == -1)
  #expect(BrowserPreviewNavigation.next.offset == 1)
  #expect(BrowserPreviewNavigation.backFive.offset == -5)
  #expect(BrowserPreviewNavigation.forwardFive.offset == 5)
}

@Test func rawPreviewRequestsDoNotFallBackToFullImageRendering() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("PixeltjeMacRawPreviewTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  // This is a valid PNG, deliberately labelled as RAW in the request. A generic
  // CIImage fallback would render it; the embedded-preview-only branch must fail.
  let png = try #require(
    Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
  let url = root.appendingPathComponent("pretend-raw.png")
  try png.write(to: url)
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
  let file = BrowserFile(
    url: url,
    relativePath: url.lastPathComponent,
    kind: .cameraRaw,
    byteLength: UInt64(values.fileSize ?? 0),
    modificationDate: values.contentModificationDate
  )

  let renderer = try BrowserPreviewRenderer()
  do {
    _ = try await renderer.preview(for: file, maximumPixelSize: 128)
    Issue.record(
      "A RAW preview request decoded the primary image instead of requiring an embedded preview"
    )
  } catch let error as PixeltjeMacError {
    #expect(error.title == "Preview unavailable")
  }
}
