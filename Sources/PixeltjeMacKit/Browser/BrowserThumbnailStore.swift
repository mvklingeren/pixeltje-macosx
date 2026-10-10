import AppKit

@MainActor
final class BrowserThumbnailStore {
  static let maximumPixelSize = 1_024

  private final class CachedPreview {
    let value: BrowserPreview

    init(_ value: BrowserPreview) {
      self.value = value
    }
  }

  private struct InFlight {
    let id: UUID
    let task: Task<BrowserPreview, Error>
    var completions: [Completion]
    var prefetchCompletion: ((Result<BrowserPreview, Error>) -> Void)?
  }

  private struct Completion {
    let id: UUID
    let receive: (Result<BrowserPreview, Error>) -> Void
  }

  private let renderer: BrowserPreviewRenderer
  private let cache = NSCache<NSString, CachedPreview>()
  private var failures: [String: String] = [:]
  private var inFlight: [String: InFlight] = [:]
  /// The viewport buffer. Entries may have no visible cell yet, which is why
  /// its ownership is separate from completion callbacks.
  private var prefetchedKeys: Set<String> = []

  init(renderer: BrowserPreviewRenderer) {
    self.renderer = renderer
    cache.totalCostLimit = 256 * 1_024 * 1_024
  }

  /// The fullscreen browser preview shares this renderer so its RAW policy is
  /// exactly the same as the thumbnail's embedded-preview-only policy.
  var previewRenderer: BrowserPreviewRenderer { renderer }

  func cached(_ file: BrowserFile) -> BrowserPreview? {
    cache.object(forKey: key(for: file) as NSString)?.value
  }

  func failure(_ file: BrowserFile) -> String? {
    failures[key(for: file)]
  }

  @discardableResult
  func request(
    _ file: BrowserFile,
    completion: @escaping (Result<BrowserPreview, Error>) -> Void
  ) -> UUID? {
    let cacheKey = key(for: file)
    if let cached = cache.object(forKey: cacheKey as NSString)?.value {
      completion(.success(cached))
      return nil
    }
    if let failure = failures[cacheKey] {
      completion(.failure(PixeltjeMacError("Preview unavailable", failure)))
      return nil
    }
    let completionID = UUID()
    let listener = Completion(id: completionID, receive: completion)
    if var flight = inFlight[cacheKey] {
      flight.completions.append(listener)
      inFlight[cacheKey] = flight
      return completionID
    }

    start(file, cacheKey: cacheKey, completions: [listener])
    return completionID
  }

  /// Starts a bounded look-ahead buffer around the viewport. It shares work
  /// with visible cells and is dropped as soon as the browser moves away.
  func setPrefetchFiles(
    _ files: [BrowserFile],
    onCompletion: ((BrowserFile, Result<BrowserPreview, Error>) -> Void)? = nil
  ) {
    let desired = Set(files.map(key(for:)))
    let leaving = prefetchedKeys.subtracting(desired)
    let entering = desired.subtracting(prefetchedKeys)
    prefetchedKeys = desired

    for cacheKey in leaving {
      if var flight = inFlight[cacheKey] {
        flight.prefetchCompletion = nil
        inFlight[cacheKey] = flight
      }
      cancelIfUnobserved(cacheKey: cacheKey)
    }
    for file in files {
      let cacheKey = key(for: file)
      guard entering.contains(cacheKey) else { continue }
      if let cached = cache.object(forKey: cacheKey as NSString)?.value {
        onCompletion?(file, .success(cached))
      } else if let failure = failures[cacheKey] {
        onCompletion?(file, .failure(PixeltjeMacError("Preview unavailable", failure)))
      } else if var flight = inFlight[cacheKey] {
        flight.prefetchCompletion = onCompletion.map { completion in { completion(file, $0) } }
        inFlight[cacheKey] = flight
      } else {
        start(
          file,
          cacheKey: cacheKey,
          completions: [],
          prefetchCompletion: onCompletion.map { completion in { completion(file, $0) } }
        )
      }
    }
  }

  func cancel(_ file: BrowserFile, requestID: UUID?) {
    guard let requestID else { return }
    let cacheKey = key(for: file)
    guard var flight = inFlight[cacheKey] else { return }
    flight.completions.removeAll { $0.id == requestID }
    inFlight[cacheKey] = flight
    cancelIfUnobserved(cacheKey: cacheKey)
  }

  func cancelAll() {
    let tasks = inFlight.values.map(\.task)
    inFlight.removeAll()
    prefetchedKeys.removeAll()
    for task in tasks {
      task.cancel()
    }
  }

  private func finish(
    cacheKey: String,
    id: UUID,
    result: Result<BrowserPreview, Error>
  ) {
    guard let flight = inFlight[cacheKey], flight.id == id else { return }
    inFlight.removeValue(forKey: cacheKey)

    switch result {
    case .success(let preview):
      let cost = preview.image.bytesPerRow * preview.image.height
      cache.setObject(CachedPreview(preview), forKey: cacheKey as NSString, cost: cost)
    case .failure(let error):
      if error is CancellationError { return }
      failures[cacheKey] = error.userFacingMessage
    }
    for completion in flight.completions {
      completion.receive(result)
    }
    flight.prefetchCompletion?(result)
  }

  private func start(
    _ file: BrowserFile,
    cacheKey: String,
    completions: [Completion],
    prefetchCompletion: ((Result<BrowserPreview, Error>) -> Void)? = nil
  ) {
    let id = UUID()
    let renderer = self.renderer
    let task = Task<BrowserPreview, Error> {
      try await renderer.preview(for: file, maximumPixelSize: Self.maximumPixelSize)
    }
    inFlight[cacheKey] = InFlight(
      id: id,
      task: task,
      completions: completions,
      prefetchCompletion: prefetchCompletion
    )

    Task { [weak self] in
      let result: Result<BrowserPreview, Error>
      do {
        result = .success(try await task.value)
      } catch {
        result = .failure(error)
      }
      self?.finish(cacheKey: cacheKey, id: id, result: result)
    }
  }

  private func cancelIfUnobserved(cacheKey: String) {
    guard
      let flight = inFlight[cacheKey],
      flight.completions.isEmpty,
      !prefetchedKeys.contains(cacheKey)
    else { return }
    inFlight.removeValue(forKey: cacheKey)
    flight.task.cancel()
  }

  private func key(for file: BrowserFile) -> String {
    file.cacheKey(maximumPixelSize: Self.maximumPixelSize)
  }
}
