import CoreImage
import Foundation
import FoundationModels
import IOSurface
import Metal

@Generable
private struct GeneratedSubjectTags {
  @Guide(description: "Short names of distinct, visible subjects that can be selected in the image.", .maximumCount(32))
  var labels: [String]
}

/// Keeps image understanding off the render and histogram actors. The system
/// model is optional; callers combine its subject names with Vision's image
/// classifications when available.
actor ImageSubjectTagger {
  private let context: CIContext
  private let workingColorSpace: CGColorSpace
  private let displayColorSpace: CGColorSpace
  private var cachedResult: (documentID: UUID, revision: UInt64, contentRevision: UInt64,
    tags: [ImageContentTag])?

  init(device: any MTLDevice) throws {
    guard
      let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
      let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else {
      throw PixeltjeMacError("Color space unavailable", "Subject tagging needs an sRGB image.")
    }
    self.workingColorSpace = workingColorSpace
    self.displayColorSpace = displayColorSpace
    self.context = CIContext(
      mtlDevice: device,
      options: [.workingColorSpace: workingColorSpace, .workingFormat: CIFormat.RGBAh]
    )
  }

  /// Returns nil when no generated suggestions can be added to Vision's tags.
  func suggestTags(for frame: RenderedFrame) async throws -> [ImageContentTag]? {
    guard !frame.isProxy else { return nil }
    if let cachedResult,
      cachedResult.documentID == frame.documentID,
      cachedResult.revision == frame.revision,
      cachedResult.contentRevision == frame.contentRevision
    {
      return cachedResult.tags
    }

    let model = SystemLanguageModel.default
    guard model.isAvailable,
      model.capabilities.contains(.vision),
      model.capabilities.contains(.guidedGeneration)
    else { return nil }
    try Task.checkCancellation()
    guard let image = displayImage(for: frame) else { return nil }
    try Task.checkCancellation()

    let session = LanguageModelSession(model: model, instructions: """
      Name only subjects visibly present in the supplied image. Return short,
      distinct noun phrases useful for selecting an object. Include people,
      animals, and physical objects, including small ones when recognizable.
      Do not guess identities or hidden objects. Omit synonyms, scene types,
      lighting, colors alone, styles, and actions.
      """)
    let response = try await session.respond(
      generating: GeneratedSubjectTags.self,
      options: GenerationOptions(samplingMode: .greedy)
    ) {
      "List the distinct visible subjects in this image. Return at most 32 labels."
      Attachment(image)
    }
    try Task.checkCancellation()
    let tags = normalizedSubjectTags(response.content.labels)
    guard !tags.isEmpty else { return nil }
    cachedResult = (frame.documentID, frame.revision, frame.contentRevision, tags)
    return tags
  }

  private func displayImage(for frame: RenderedFrame) -> CGImage? {
    let maximumEdge: CGFloat = 2048
    let scale = min(1, maximumEdge / CGFloat(max(frame.width, frame.height)))
    let extent = CGRect(
      x: 0, y: 0,
      width: max(1, Int((CGFloat(frame.width) * scale).rounded())),
      height: max(1, Int((CGFloat(frame.height) * scale).rounded())))
    let source = CIImage(ioSurface: frame.surface, options: [.colorSpace: workingColorSpace])
    let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .cropped(to: extent)
      .composited(over: CIImage(color: .white).cropped(to: extent))
    return context.createCGImage(scaled, from: extent, format: .RGBA8,
      colorSpace: displayColorSpace)
  }

  func clearCaches() {
    cachedResult = nil
    context.clearCaches()
  }
}

/// Model output is a suggestion, never executable input. Normalize it before
/// using the strings as button identities and object-selection prompts.
func normalizedSubjectTags(_ labels: [String]) -> [ImageContentTag] {
  var seen = Set<String>()
  var tags: [ImageContentTag] = []
  let punctuation = CharacterSet(charactersIn: " .,:;!?\"'\n\r\t")
  for raw in labels {
    let label = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .trimmingCharacters(in: punctuation)
    guard !label.isEmpty, label.count <= 80,
      label.split(separator: " ").count <= 8
    else { continue }
    let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
    guard seen.insert(key).inserted else { continue }
    tags.append(ImageContentTag(id: label, isRecommended: true,
      source: .foundationModel))
    if tags.count == 32 { break }
  }
  return tags
}
