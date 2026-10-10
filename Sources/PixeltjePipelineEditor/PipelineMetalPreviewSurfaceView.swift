import AppKit
import PixeltjePipelineEngine
import QuartzCore
import SwiftUI

/// Presents engine-owned surfaces without decoding or copying their pixels to
/// an NSImage. Each view draws on the preview render thread, so card and
/// full-screen previews keep their cadence while the main thread is busy.
struct PipelineMetalPreviewSurfaceView: NSViewRepresentable {
  let presenter: PipelineLivePreviewPresenter

  func makeNSView(context: Context) -> PipelineMetalPreviewLayerView {
    let view = PipelineMetalPreviewLayerView()
    view.attach(to: presenter)
    return view
  }

  func updateNSView(_ view: PipelineMetalPreviewLayerView, context: Context) {
    view.attach(to: presenter)
  }

  static func dismantleNSView(_ view: PipelineMetalPreviewLayerView, coordinator: ()) {
    view.detachFromPresenter()
  }
}

/// Hosts the Metal layer that its renderer draws on the render thread. The
/// view only reports the layer's pixel size and whether it can be seen.
@MainActor
final class PipelineMetalPreviewLayerView: NSView {
  let renderer: PipelineLivePreviewLayerRenderer
  private let metalLayer = CAMetalLayer()
  private weak var presenter: PipelineLivePreviewPresenter?
  private var occlusionObserver: (any NSObjectProtocol)?
  private(set) var isPreviewVisible = false

  init() {
    renderer = PipelineLivePreviewLayerRenderer(layer: metalLayer)
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    setAccessibilityRole(.image)
    setAccessibilityLabel("Metal render preview")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PipelineMetalPreviewLayerView is created programmatically")
  }

  override func makeBackingLayer() -> CALayer { metalLayer }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {}

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    updateDrawableSize()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    metalLayer.contentsScale = window?.backingScaleFactor ?? metalLayer.contentsScale
    updateDrawableSize()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if let occlusionObserver {
      NotificationCenter.default.removeObserver(occlusionObserver)
      self.occlusionObserver = nil
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window {
      occlusionObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window,
        queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateVisibility() }
      }
      metalLayer.contentsScale = window.backingScaleFactor
    }
    updateDrawableSize()
  }

  override func viewDidHide() {
    super.viewDidHide()
    updateVisibility()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateVisibility()
  }

  func attach(to presenter: PipelineLivePreviewPresenter) {
    guard self.presenter !== presenter else { return }
    self.presenter?.detach(self)
    self.presenter = presenter
    presenter.attach(self)
  }

  /// Called once SwiftUI removes the view; its renderer stops for good.
  func detachFromPresenter() {
    presenter?.detach(self)
    presenter = nil
    renderer.stop()
  }

  private func updateDrawableSize() {
    let size = convertToBacking(bounds).size
    renderer.setDrawableSize(CGSize(
      width: max(size.width.rounded(), 0), height: max(size.height.rounded(), 0)))
    updateVisibility()
  }

  private func updateVisibility() {
    let visible = window?.occlusionState.contains(.visible) == true
      && !isHiddenOrHasHiddenAncestor && !bounds.isEmpty
    guard visible != isPreviewVisible else { return }
    isPreviewVisible = visible
    renderer.setVisible(visible)
    presenter?.visibilityDidChange(self)
  }
}
