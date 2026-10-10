import AppKit

struct BrowserProgress: Equatable {
  var loaded: Int
  var total: Int
  var isScanning: Bool
}

@MainActor
final class BrowserViewController: NSViewController {
  let folder: URL
  var progressChanged: ((BrowserProgress) -> Void)?

  var thumbnailSize: CGFloat {
    didSet {
      let clamped = min(max(thumbnailSize, 90), 420)
      if clamped != thumbnailSize {
        thumbnailSize = clamped
        return
      }
      layout.preferredRowHeight = clamped
      UserDefaults.standard.set(Double(clamped), forKey: BrowserPreferences.thumbnailSizeKey)
    }
  }

  private let openFile: (BrowserFile) -> Void
  private let store: BrowserThumbnailStore
  private let layout = JustifiedImageLayout()
  private let collectionView = BrowserCollectionView()
  private let scrollView = NSScrollView()
  private let emptyLabel = NSTextField(labelWithString: "")

  private var files: [BrowserFile] = []
  private var aspects: [CGFloat?] = []
  private var completedURLs: Set<URL> = []
  private var scanTask: Task<Void, Never>?
  private var scanGeneration: UInt64 = 0
  private var scannedRecursively = BrowserPreferences.scansSubfolders
  private var isScanning = true
  private var reflowScheduled = false
  private var prefetchScheduled = false
  private var fullscreenPreview: BrowserFullscreenPreviewWindowController?

  private static let prefetchBehind = 8

  init(
    folder: URL,
    renderer: BrowserPreviewRenderer,
    openFile: @escaping (BrowserFile) -> Void
  ) {
    self.folder = folder
    self.store = BrowserThumbnailStore(renderer: renderer)
    self.openFile = openFile
    self.thumbnailSize = CGFloat(BrowserPreferences.thumbnailSize)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("BrowserViewController is created programmatically")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true

    layout.dataSource = self
    layout.preferredRowHeight = thumbnailSize
    applyMargin()

    collectionView.collectionViewLayout = layout
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.isSelectable = true
    collectionView.allowsEmptySelection = true
    collectionView.allowsMultipleSelection = false
    collectionView.backgroundColors = [.clear]
    collectionView.register(
      BrowserCollectionItem.self,
      forItemWithIdentifier: BrowserCollectionItem.identifier
    )
    collectionView.openItem = { [weak self] indexPath in
      self?.openItem(at: indexPath)
    }

    scrollView.documentView = collectionView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.automaticallyAdjustsContentInsets = true
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(scrollView)

    emptyLabel.font = .systemFont(ofSize: 15)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.maximumNumberOfLines = 3
    emptyLabel.isHidden = true
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
    ])
    view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(preferencesChanged),
      name: UserDefaults.didChangeNotification,
      object: UserDefaults.standard
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(viewportDidChange),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    scan()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(collectionView)
    schedulePrefetch()
  }

  func cancel() {
    scanGeneration &+= 1
    scanTask?.cancel()
    scanTask = nil
    store.cancelAll()
    store.setPrefetchFiles([])
    fullscreenPreview?.close()
    fullscreenPreview = nil
  }

  private func scan() {
    scanGeneration &+= 1
    let generation = scanGeneration
    scanTask?.cancel()
    store.cancelAll()
    scannedRecursively = BrowserPreferences.scansSubfolders
    let recursively = scannedRecursively
    let folder = self.folder
    isScanning = true
    reportProgress()

    scanTask = Task { [weak self] in
      let found = await Task.detached(priority: .userInitiated) {
        ImageFolderScanner.files(in: folder, recursively: recursively)
      }.value
      guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
      self.adopt(found)
      self.scanTask = nil
    }
  }

  private func adopt(_ found: [BrowserFile]) {
    files = found
    aspects = Array(repeating: nil, count: found.count)
    completedURLs.removeAll(keepingCapacity: true)
    isScanning = false
    collectionView.reloadData()
    schedulePrefetch()
    emptyLabel.isHidden = !found.isEmpty
    if found.isEmpty {
      let scope = scannedRecursively ? "this folder or its subfolders" : "this folder"
      emptyLabel.stringValue = "No images supported by the installed system were found in \(scope)."
    } else {
      collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
    }
    reportProgress()
  }

  @objc private func preferencesChanged() {
    applyMargin()
    if BrowserPreferences.scansSubfolders != scannedRecursively {
      scan()
    } else {
      schedulePrefetch()
    }
  }

  private func applyMargin() {
    let margin = CGFloat(BrowserPreferences.margin)
    layout.spacing = margin
    layout.insets = NSEdgeInsets(
      top: margin,
      left: margin,
      bottom: margin + 8,
      right: margin
    )
  }

  private func openItem(at indexPath: IndexPath) {
    guard files.indices.contains(indexPath.item) else { return }
    openFile(files[indexPath.item])
  }

  private func previewItem(_ file: BrowserFile, from cell: BrowserCollectionItem) {
    fullscreenPreview?.close()
    let controller = BrowserFullscreenPreviewWindowController(
      renderer: store.previewRenderer,
      on: cell.view.window?.screen
    )
    controller.closed = { [weak self] closedController in
      guard self?.fullscreenPreview === closedController else { return }
      self?.fullscreenPreview = nil
    }
    controller.navigateRequested = { [weak self] direction in
      self?.navigateFullscreenPreview(direction)
    }
    fullscreenPreview = controller
    controller.show(file)
  }

  private func navigateFullscreenPreview(_ direction: BrowserPreviewNavigation) {
    guard
      let controller = fullscreenPreview,
      let currentFile = controller.currentFile,
      let currentIndex = files.firstIndex(where: { $0.url == currentFile.url })
    else { return }

    let destination = min(max(currentIndex + direction.offset, 0), files.count - 1)
    guard destination != currentIndex else { return }
    let indexPath = IndexPath(item: destination, section: 0)
    collectionView.selectionIndexPaths = [indexPath]
    collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
    controller.show(files[destination])
  }

  private func receive(
    _ result: Result<BrowserPreview, Error>,
    for requestedFile: BrowserFile,
    at indexPath: IndexPath,
    generation: UInt64,
    cell: BrowserCollectionItem?
  ) {
    guard
      generation == scanGeneration,
      files.indices.contains(indexPath.item),
      files[indexPath.item].url == requestedFile.url
    else { return }

    switch result {
    case .success(let preview):
      files[indexPath.item].kind = preview.sourceKind
      let aspect = CGFloat(preview.image.width) / CGFloat(max(preview.image.height, 1))
      noteCompletion(for: requestedFile.url, aspect: aspect, at: indexPath.item)
      if let cell, cell.representedURL == requestedFile.url {
        cell.show(
          preview,
          name: requestedFile.displayName,
          url: requestedFile.url,
          animated: true
        )
      }
    case .failure(let error):
      guard !(error is CancellationError) else { return }
      noteCompletion(for: requestedFile.url, aspect: nil, at: indexPath.item)
      if let cell, cell.representedURL == requestedFile.url {
        cell.showFailure(name: requestedFile.displayName, url: requestedFile.url)
        cell.view.toolTip = error.userFacingMessage
      }
    }
  }

  private func noteCompletion(for url: URL, aspect: CGFloat?, at index: Int) {
    guard files.indices.contains(index) else { return }
    if
      let aspect,
      aspect.isFinite,
      aspect > 0,
      aspects[index] != aspect
    {
      aspects[index] = aspect
      scheduleReflow()
    }
    if completedURLs.insert(url).inserted {
      reportProgress()
    }
  }

  private func scheduleReflow() {
    guard !reflowScheduled else { return }
    reflowScheduled = true
    let generation = scanGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self, self.scanGeneration == generation else { return }
      self.reflowScheduled = false
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.allowsImplicitAnimation = true
        self.layout.invalidateLayout()
      }
    }
  }

  @objc private func viewportDidChange(_ notification: Notification) {
    refreshVisibleHoverStates()
    schedulePrefetch()
  }

  private func refreshVisibleHoverStates() {
    for case let cell as BrowserCollectionItem in collectionView.visibleItems() {
      cell.refreshHoverState()
    }
  }

  private func schedulePrefetch() {
    guard isViewLoaded, !prefetchScheduled else { return }
    prefetchScheduled = true
    let generation = scanGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.prefetchScheduled = false
      guard self.scanGeneration == generation else { return }
      self.prefetchAroundViewport()
    }
  }

  private func prefetchAroundViewport() {
    let visibleItems = layout.layoutAttributesForElements(in: collectionView.visibleRect)
    let indexes = visibleItems.compactMap(\.indexPath?.item).filter { files.indices.contains($0) }
    guard let firstVisible = indexes.min(), let lastVisible = indexes.max() else {
      store.setPrefetchFiles([])
      return
    }
    let first = max(firstVisible - Self.prefetchBehind, 0)
    let last = min(lastVisible + BrowserPreferences.preloadCount, files.count - 1)
    let generation = scanGeneration
    store.setPrefetchFiles(Array(files[first...last])) { [weak self] file, result in
      self?.receivePrefetched(result, for: file, generation: generation)
    }
  }

  /// Unlike a visible cell's completion, this records the dimensions while the
  /// thumbnail is still ahead of the viewport. By the time AppKit asks for its
  /// item, the justified layout already has the final aspect ratio.
  private func receivePrefetched(
    _ result: Result<BrowserPreview, Error>,
    for file: BrowserFile,
    generation: UInt64
  ) {
    guard
      generation == scanGeneration,
      let index = files.firstIndex(where: { $0.url == file.url })
    else { return }

    switch result {
    case .success(let preview):
      files[index].kind = preview.sourceKind
      let aspect = CGFloat(preview.image.width) / CGFloat(max(preview.image.height, 1))
      noteCompletion(for: file.url, aspect: aspect, at: index)
    case .failure(let error):
      guard !(error is CancellationError) else { return }
      noteCompletion(for: file.url, aspect: nil, at: index)
    }
  }

  private func reportProgress() {
    progressChanged?(
      BrowserProgress(
        loaded: completedURLs.count,
        total: files.count,
        isScanning: isScanning
      ))
  }
}

extension BrowserViewController: NSCollectionViewDataSource {
  func collectionView(
    _ collectionView: NSCollectionView,
    numberOfItemsInSection section: Int
  ) -> Int {
    files.count
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let item = collectionView.makeItem(
      withIdentifier: BrowserCollectionItem.identifier,
      for: indexPath
    )
    guard let cell = item as? BrowserCollectionItem, files.indices.contains(indexPath.item) else {
      return item
    }

    let file = files[indexPath.item]
    cell.thumbnailRequestID = nil
    cell.previewRequested = { [weak self, weak cell] in
      guard let self, let cell, cell.representedURL == file.url else { return }
      self.previewItem(file, from: cell)
    }
    if let preview = store.cached(file) {
      let aspect = CGFloat(preview.image.width) / CGFloat(max(preview.image.height, 1))
      noteCompletion(for: file.url, aspect: aspect, at: indexPath.item)
      cell.show(preview, name: file.displayName, url: file.url, animated: false)
      return cell
    }
    if let failure = store.failure(file) {
      noteCompletion(for: file.url, aspect: nil, at: indexPath.item)
      cell.showFailure(name: file.displayName, url: file.url)
      cell.view.toolTip = failure
      return cell
    }

    cell.showLoading(name: file.displayName, url: file.url)
    let generation = scanGeneration
    cell.thumbnailRequestID = store.request(file) { [weak self, weak cell] result in
      self?.receive(
        result,
        for: file,
        at: indexPath,
        generation: generation,
        cell: cell
      )
    }
    return cell
  }
}

extension BrowserViewController: NSCollectionViewDelegate {
  func collectionView(
    _ collectionView: NSCollectionView,
    didEndDisplaying item: NSCollectionViewItem,
    forRepresentedObjectAt indexPath: IndexPath
  ) {
    guard files.indices.contains(indexPath.item) else { return }
    guard let cell = item as? BrowserCollectionItem else { return }
    store.cancel(files[indexPath.item], requestID: cell.thumbnailRequestID)
    cell.thumbnailRequestID = nil
  }
}

extension BrowserViewController: JustifiedImageLayoutDataSource {
  func imageLayoutAspectRatio(at index: Int) -> CGFloat? {
    aspects.indices.contains(index) ? aspects[index] : nil
  }
}
