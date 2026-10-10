import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine

public enum BaseTestSetPipelineFamily {
  public static let supportedNodeKinds: [PipelineNodeKind] = [
    PipelineNodeKind(rawValue: "primitive.string"),
    PipelineNodeKind(rawValue: "primitive.int"),
    PipelineNodeKind(rawValue: "primitive.float"),
    PipelineNodeKind(rawValue: "primitive.boolean"),
    PipelineNodeKind(rawValue: "input.resolution"),
    PipelineNodeKind(rawValue: "text.replace"),
    PipelineNodeKind(rawValue: "text.trim"),
    PipelineNodeKind(rawValue: "text.regexReplace"),
    PipelineNodeKind(rawValue: "text.regexMatch"),
    PipelineNodeKind(rawValue: "text.regexExtract"),
    PipelineNodeKind(rawValue: "text.length"),
    PipelineNodeKind(rawValue: "text.substring"),
    PipelineNodeKind(rawValue: "text.changeCase"),
    PipelineNodeKind(rawValue: "text.contains"),
    PipelineNodeKind(rawValue: "text.compare"),
    PipelineNodeKind(rawValue: "logic.ifElse"),
    PipelineNodeKind(rawValue: "text.concatenate"),
    PipelineNodeKind(rawValue: "output.text"),
    PipelineNodeKind(rawValue: "input.image"),
    PipelineNodeKind(rawValue: "input.mask"),
    PipelineNodeKind(rawValue: "input.maskImage"),
    PipelineNodeKind(rawValue: "image.dimensions"),
    PipelineNodeKind(rawValue: "math.expression"),
    PipelineNodeKind(rawValue: "image.scale"),
    PipelineNodeKind(rawValue: "image.scaleBy"),
    PipelineNodeKind(rawValue: "image.scaleToTotalPixels"),
    PipelineNodeKind(rawValue: "image.canny"),
    PipelineNodeKind(rawValue: "image.crop"),
    PipelineNodeKind(rawValue: "image.invert"),
    PipelineNodeKind(rawValue: "image.proceduralNoise"),
    PipelineNodeKind(rawValue: "image.sinusoid"),
    PipelineNodeKind(rawValue: "signal.sinusoid"),
    PipelineNodeKind(rawValue: "image.drawCurve"),
    PipelineNodeKind(rawValue: "image.translate"),
    PipelineNodeKind(rawValue: "image.blend"),
    PipelineNodeKind(rawValue: "image.batch"),
    PipelineNodeKind(rawValue: "image.fromBatch"),
    PipelineNodeKind(rawValue: "image.compositeMasked"),
    PipelineNodeKind(rawValue: "image.padForOutpaint"),
    PipelineNodeKind(rawValue: "image.fillMasked"),
    PipelineNodeKind(rawValue: "mask.solid"),
    PipelineNodeKind(rawValue: "mask.radial"),
    PipelineNodeKind(rawValue: "mask.stripes"),
    PipelineNodeKind(rawValue: "mask.composite"),
    PipelineNodeKind(rawValue: "mask.grow"),
    PipelineNodeKind(rawValue: "mask.feather"),
    PipelineNodeKind(rawValue: "mask.threshold"),
    PipelineNodeKind(rawValue: "mask.fromImage"),
    PipelineNodeKind(rawValue: "mask.crop"),
    PipelineNodeKind(rawValue: "mask.invert"),
    PipelineNodeKind(rawValue: "mask.toImage"),
    PipelineNodeKind(rawValue: "output.preview"),
    PipelineNodeKind(rawValue: "output.videoPreview"),
    PipelineNodeKind(rawValue: "output.image"),
    PipelineNodeKind(rawValue: "input.video"),
    PipelineNodeKind(rawValue: "input.audio"),
    PipelineNodeKind(rawValue: "output.audio"),
    PipelineNodeKind(rawValue: "media.videoComponents"),
    PipelineNodeKind(rawValue: "utility.reroute"),
    PipelineNodeKind(rawValue: "utility.previewAny"),
    PipelineNodeKind(rawValue: "media.createVideo"),
    PipelineNodeKind(rawValue: "output.video"),
    PipelineNodeKind(rawValue: "diffusion.karrasScheduler"),
    PipelineNodeKind(rawValue: "diffusion.exponentialScheduler"),
    PipelineNodeKind(rawValue: "diffusion.alignYourStepsScheduler"),
    PipelineNodeKind(rawValue: "diffusion.splitSchedule"),
    PipelineNodeKind(rawValue: "diffusion.splitScheduleDenoise"),
    PipelineNodeKind(rawValue: "diffusion.flipSchedule"),
    PipelineNodeKind(rawValue: "diffusion.forceFullDenoise"),
    PipelineNodeKind(rawValue: "latent.disableNoise"),
    PipelineNodeKind(rawValue: "latent.randomNoise"),
    PipelineNodeKind(rawValue: "diffusion.samplerSelector"),
    PipelineNodeKind(rawValue: "diffusion.lcmSampler"),
    PipelineNodeKind(rawValue: "latent.emptyImage"),
    PipelineNodeKind(rawValue: "latent.emptyFlux2Image"),
    PipelineNodeKind(rawValue: "latent.emptyHunyuanVideo"),
    PipelineNodeKind(rawValue: "latent.emptyLTXVVideo"),
    PipelineNodeKind(rawValue: "latent.zerosLike"),
    PipelineNodeKind(rawValue: "latent.repeatBatch"),
    PipelineNodeKind(rawValue: "latent.fromBatch"),
    PipelineNodeKind(rawValue: "latent.upscale"),
    PipelineNodeKind(rawValue: "latent.upscaleBy"),
    PipelineNodeKind(rawValue: "latent.setNoiseMask"),
  ]

  public static func makeNodeExecutors() -> [PipelineNodeExecutor] {
    supportedNodeKinds.map { kind in
      PipelineNodeExecutor(kind: kind) { node, inputValues, context in
        var inputs: [String: Value] = [:]
        for (port, wrapped) in inputValues where port != "interactionMasks" {
          inputs[port] = try Value.from(wrapped)
        }
        let result = try await BaseTestSetGraphExecutor.executeNode(
          node, inputs: inputs, context: BaseTestNodeContext(
            semanticSHA256: context.semanticSHA256,
            nodeCount: context.nodeCount,
            sourceRoot: context.sourceMediaRoot,
            invocation: context.invocation,
            progress: context.progress,
            index: context.nodeIndex))
        var outputs = result.outputs.mapValues { value -> PipelineNodeValue in
          switch value {
          case .string(let text): return PipelineNodeValue(text, type: .string)
          case .integer(let number): return PipelineNodeValue(number, type: .integer)
          case .number(let number): return PipelineNodeValue(number, type: .number)
          case .boolean(let boolean): return PipelineNodeValue(boolean, type: .boolean)
          case .mesh3D(let mesh): return PipelineNodeValue(mesh, type: .mesh3D)
          case .matrix4x4(let matrix): return PipelineNodeValue(matrix, type: .matrix4x4)
          default: return PipelineNodeValue(value, type: value.portType)
          }
        }
        if kind.rawValue == "input.image", case .image(let image)? = result.outputs["image"] {
          outputs["image"] = PipelineNodeValue(
            try PipelineImageInput(width: image.width, height: image.height, rgba: image.rgba),
            type: .image)
        }
        if kind.rawValue == "output.preview", let image = inputValues["image"] {
          outputs["image"] = image
        }
        if kind.rawValue == "output.videoPreview", let image = inputValues["image"] {
          outputs["image"] = image
        }
        var terminal = result.terminalOutput
        if case .image(var image)? = terminal, let wrapped = inputValues["interactionMasks"] {
          guard let masks = wrapped.value(as: [PipelineLabeledMask].self) else {
            throw PipelineEngineError.invalidInvocation("Image Output needs labeled interaction masks.")
          }
          try image.setInteractionMasks(masks)
          terminal = .image(image)
        }
        return PipelineNodeResult(outputs: outputs, terminalOutput: terminal)
      }
    }
  }


}

private enum Value: Sendable, PipelineTraceRepresentable {
  case string(String)
  case integer(Int)
  case number(Double)
  case curve1D(ProceduralArt.Curve1D)
  case mesh3D(PipelineMesh3D)
  case matrix4x4(PipelineMatrix4x4)
  case boolean(Bool)
  case image(BaseTestSetImage)
  case imageBatch([BaseTestSetImage])
  case mask(BaseTestSetMask)
  case audio(URL)
  case video(BaseTestSetVideo)
  case schedule([Double])
  case latent(PipelineLatent)
  case noise(String)
  case sampler(String)

  func pipelineTraceValue() -> PipelineTraceValue {
    switch self {
    case .string(let value): return .text(value)
    case .integer(let value): return .init(type: "integer", summary: String(value))
    case .number(let value): return .init(type: "number", summary: String(value))
    case .curve1D(let value):
      return .init(type: "curve1D", summary: value.summary)
    case .mesh3D(let value): return value.pipelineTraceValue()
    case .matrix4x4(let value): return value.pipelineTraceValue()
    case .boolean(let value): return .init(type: "boolean", summary: String(value))
    case .image(let image):
      return .image(width: image.width, height: image.height) { x, y in
        let offset = (y * image.width + x) * 4
        return (image.rgba[offset], image.rgba[offset + 1],
          image.rgba[offset + 2], image.rgba[offset + 3])
      }
    case .imageBatch(let images):
      guard let first = images.first else {
        return .init(type: "image", summary: "Empty image batch")
      }
      var preview = PipelineTraceValue.image(
        width: first.width, height: first.height) { x, y in
          let offset = (y * first.width + x) * 4
          return (first.rgba[offset], first.rgba[offset + 1],
            first.rgba[offset + 2], first.rgba[offset + 3])
        }
      preview.summary = "Image batch (\(images.count) frames), first \(first.width) × \(first.height)"
      return preview
    case .mask(let mask):
      return .image(width: mask.width, height: mask.height, type: "mask") { x, y in
        let value = mask.values[y * mask.width + x]
        return (value, value, value, 1)
      }
    case .audio(let url): return .init(type: "audio", summary: url.lastPathComponent)
    case .video(let video):
      return .init(type: "video", summary: "Video (\(video.frameCount) frames)")
    case .schedule(let values):
      return .text(values.map { String($0) }.joined(separator: ", "), type: "schedule")
    case .latent(let latent):
      return .init(type: "latent", summary: "Shape \(latent.shape.map { $0.map(String.init) ?? "?" }.joined(separator: " × "))")
    case .noise(let value): return .init(type: "noise", summary: value)
    case .sampler(let value): return .init(type: "samplerFunction", summary: value)
    }
  }
}

private struct BaseTestNodeContext: Sendable {
  var semanticSHA256: String
  var nodeCount: Int
  var sourceRoot: URL?
  var invocation: PipelineInvocation
  var progress: PipelineExecutionProgressHandler
  var index: Int
}

private struct BaseTestNodeResult: Sendable {
  var outputs: [String: Value]
  var terminalOutput: PipelineExecutionOutput?
}

private enum BaseTestSetGraphExecutor {
  static func executeNode(
    _ node: PipelineNode,
    inputs: [String: Value],
    context: BaseTestNodeContext
  ) async throws -> BaseTestNodeResult {
    let semanticSHA256 = context.semanticSHA256
    let nodeCount = context.nodeCount
    let sourceRoot = context.sourceRoot
    let invocation = context.invocation
    let progress = context.progress
    let index = context.index
    let nodeID = node.id
    var outputs: [String: Value] = [:]
    var finalOutput: PipelineExecutionOutput?
    func input(_ node: PipelineNode, _ port: String) -> Value? { inputs[port] }
    func required(_ node: PipelineNode, _ port: String) throws -> Value {
      guard let value = inputs[port] else {
        throw BaseTestSetError.invalid("\(node.id.rawValue) is missing \(port).")
      }
      return value
    }
    func emit(_ node: PipelineNode, _ port: String, _ value: Value) {
      outputs[port] = value
    }
    switch node.kind.rawValue {
    case "primitive.string":
      let value = try input(node, "value")?.string ?? node.string("value", default: "")
      emit(node, "value", .string(value))
    case "primitive.int":
      emit(node, "value", .integer(try input(node, "value")?.integer
        ?? node.integer("value", default: 0)))
    case "primitive.float":
      let value = try input(node, "value")?.number ?? node.number("value", default: 0)
      guard value.isFinite else {
        throw BaseTestSetError.invalid("Number must be finite.")
      }
      emit(node, "value", .number(value))
    case "primitive.boolean":
      emit(node, "value", .boolean(try input(node, "value")?.boolean
        ?? node.boolean("value", default: false)))
    case "input.resolution":
      let ratio = try node.string("aspectRatio", default: "1:1 (Square)")
      let megapixels = try node.number("megapixels", default: 1)
      let multiple = try node.integer("multiple", default: 8)
      let size = try BaseTestSetScalarOperations.resolution(
        aspectRatio: ratio, megapixels: megapixels, multiple: multiple)
      emit(node, "width", .integer(size.width))
      emit(node, "height", .integer(size.height))
    case "text.replace":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      let find = try input(node, "find")?.string ?? node.string("find", default: "")
      let replacement = try input(node, "replace")?.string
        ?? node.string("replace", default: "")
      emit(node, "value", .string(BaseTestSetScalarOperations.replacing(
        value, find: find, with: replacement)))
    case "text.trim":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      let mode = try node.string("mode", default: "Both")
      let set = CharacterSet.whitespacesAndNewlines
      let result: String
      switch mode {
      case "Both": result = value.trimmingCharacters(in: set)
      case "Left": result = String(value.drop(while: { $0.isWhitespace }))
      case "Right": result = String(value.reversed().drop(while: { $0.isWhitespace }).reversed())
      default: throw BaseTestSetError.invalid("Unsupported trim mode \(mode).")
      }
      emit(node, "value", .string(result))
    case "text.regexReplace":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      let pattern = try input(node, "pattern")?.string ?? node.string("pattern", default: "")
      let replacement = try input(node, "replacement")?.string
        ?? node.string("replacement", default: "")
      let count = try input(node, "count")?.integer ?? node.integer("count", default: 0)
      guard count >= 0 else { throw BaseTestSetError.invalid("Regex count must be non-negative.") }
      let regex = try NSRegularExpression(pattern: pattern, options: [
        (try input(node, "caseInsensitive")?.boolean
          ?? node.boolean("caseInsensitive", default: true)) ? .caseInsensitive : [],
        (try input(node, "multiline")?.boolean
          ?? node.boolean("multiline", default: false)) ? .anchorsMatchLines : [],
        (try input(node, "dotAll")?.boolean
          ?? node.boolean("dotAll", default: false)) ? .dotMatchesLineSeparators : [],
      ])
      let range = NSRange(value.startIndex..<value.endIndex, in: value)
      let result: String
      if count == 0 {
        result = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
      } else {
        let matches = Array(regex.matches(in: value, range: range).prefix(count))
        var copy = value
        for match in matches.reversed() {
          guard let swiftRange = Range(match.range, in: copy) else { continue }
          copy.replaceSubrange(swiftRange, with: regex.replacementString(
            for: match, in: value, offset: 0, template: replacement))
        }
        result = copy
      }
      emit(node, "value", .string(result))
    case "text.regexMatch", "text.regexExtract":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      let pattern = try input(node, "pattern")?.string ?? node.string("pattern", default: "")
      let options: NSRegularExpression.Options = [
        (try input(node, "caseInsensitive")?.boolean
          ?? node.boolean("caseInsensitive", default: true)) ? .caseInsensitive : [],
        (try input(node, "multiline")?.boolean
          ?? node.boolean("multiline", default: false)) ? .anchorsMatchLines : [],
        (try input(node, "dotAll")?.boolean
          ?? node.boolean("dotAll", default: false)) ? .dotMatchesLineSeparators : [],
      ]
      let regex = try? NSRegularExpression(pattern: pattern, options: options)
      let matches = regex?.matches(in: value, range: NSRange(value.startIndex..., in: value)) ?? []
      if node.kind.rawValue == "text.regexMatch" {
        emit(node, "result", .boolean(!matches.isEmpty))
      } else {
        let mode = try node.string("mode", default: "First Match")
        let group = try input(node, "groupIndex")?.integer
          ?? node.integer("groupIndex", default: 1)
        emit(node, "value", .string(try BaseTestSetScalarOperations.extract(
          from: value, matches: matches, mode: mode, groupIndex: group)))
      }
    case "text.length":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      emit(node, "length", .integer(value.unicodeScalars.count))
    case "text.substring":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      let start = try input(node, "start")?.integer ?? node.integer("start", default: 0)
      let end = try input(node, "end")?.integer ?? node.integer("end", default: 0)
      emit(node, "value", .string(BaseTestSetScalarOperations.substring(
        value, start: start, end: end)))
    case "text.changeCase":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      let mode = try node.string("mode", default: "UPPERCASE")
      let result: String
      switch mode {
      case "Title Case", "Capitalize": result = value.capitalized
      case "UPPERCASE": result = value.uppercased()
      case "lowercase": result = value.lowercased()
      default: throw BaseTestSetError.invalid("Unsupported case mode \(mode).")
      }
      emit(node, "value", .string(result))
    case "text.contains":
      let value = try input(node, "string")?.string ?? node.string("string", default: "")
      let substring = try input(node, "substring")?.string
        ?? node.string("substring", default: "")
      let sensitive = try input(node, "caseSensitive")?.boolean
        ?? node.boolean("caseSensitive", default: true)
      emit(node, "result", .boolean(sensitive ? value.contains(substring)
        : value.lowercased().contains(substring.lowercased())))
    case "text.compare":
      let first = try input(node, "stringA")?.string ?? node.string("stringA", default: "")
      let second = try input(node, "stringB")?.string ?? node.string("stringB", default: "")
      let sensitive = try input(node, "caseSensitive")?.boolean
        ?? node.boolean("caseSensitive", default: true)
      let a = sensitive ? first : first.lowercased()
      let b = sensitive ? second : second.lowercased()
      let mode = try node.string("mode", default: "Equal")
      let result: Bool
      switch mode {
      case "Equal": result = a == b
      case "Starts With": result = a.hasPrefix(b)
      case "Ends With": result = a.hasSuffix(b)
      default: throw BaseTestSetError.invalid("Unsupported comparison mode \(mode).")
      }
      emit(node, "result", .boolean(result))
    case "logic.ifElse":
      let condition = try input(node, "condition")?.boolean
        ?? node.boolean("condition", default: false)
      emit(node, "value", try required(node, condition ? "trueValue" : "falseValue"))
    case "text.concatenate":
      let first = try input(node, "stringA")?.string ?? node.string("stringA", default: "")
      let second = try input(node, "stringB")?.string ?? node.string("stringB", default: "")
      let delimiter = try input(node, "delimiter")?.string
        ?? node.string("delimiter", default: "")
      emit(node, "value", .string(first + delimiter + second))
    case "output.text":
      let text = try required(node, "text").string
      finalOutput = .plainText(PipelinePlainText(
        text: text, semanticPipelineSHA256: semanticSHA256))

    case "input.image":
      let image: BaseTestSetImage
      if case .image(let host)? = invocation[PipelineInvocation.sourceImageKey] {
        image = try BaseTestSetImage(width: host.width, height: host.height, rgba: host.rgba)
      } else if case .string(let name)? = node.parameters["sourceName"], !name.isEmpty {
        image = try BaseTestSetImage.loadPNG(at: sourceURL(name: name, root: sourceRoot))
      } else {
        throw BaseTestSetError.invalid(
          "Source Image needs a sourceName or host sourceImage input.")
      }
      emit(node, "image", .image(image))
      emit(node, "mask", .mask(try BaseTestSetMask(channel: "alpha", of: image).inverted()))
    case "input.mask":
      guard case .mask(let host)? = invocation[PipelineInvocation.selectionMaskKey] else {
        throw BaseTestSetError.invalid("Selection Mask needs a host selectionMask input.")
      }
      emit(node, "mask", .mask(try BaseTestSetMask(host: host)))
    case "input.maskImage":
      let name = try node.string("sourceName")
      let image = try BaseTestSetImage.loadPNG(at: sourceURL(name: name, root: sourceRoot))
      let channel = try node.string("channel", default: "alpha")
      let mask = try BaseTestSetMask(channel: channel, of: image)
      emit(node, "mask", .mask(channel.lowercased() == "alpha" ? mask.inverted() : mask))
    case "image.dimensions":
      let source = try required(node, "image")
      let image: BaseTestSetImage
      let batchSize: Int
      switch source {
      case .image(let value): image = value; batchSize = 1
      case .imageBatch(let values):
        guard let first = values.first else {
          throw BaseTestSetError.invalid("Image batch is empty.")
        }
        image = first; batchSize = values.count
      default: throw BaseTestSetError.invalid("Image Dimensions expects an image or image batch.")
      }
      emit(node, "width", .integer(image.width))
      emit(node, "height", .integer(image.height))
      emit(node, "batchSize", .integer(batchSize))
    case "math.expression":
      let expression = try node.string("expression").replacingOccurrences(of: " ", with: "")
      guard expression.count > 2, expression.first == "a",
        let operation = expression.dropFirst().first,
        let operand = Double(expression.dropFirst(2)), operand.isFinite
      else {
        throw BaseTestSetError.invalid("Unsupported fixture expression \(expression).")
      }
      let a = try required(node, "a").number
      let result: Double
      switch operation {
      case "+": result = a + operand
      case "-": result = a - operand
      case "*": result = a * operand
      case "/" where operand != 0: result = a / operand
      default:
        throw BaseTestSetError.invalid("Unsupported fixture expression \(expression).")
      }
      guard result.isFinite, result > Double(Int.min), result < Double(Int.max) else {
        throw BaseTestSetError.invalid("Math expression result is out of range.")
      }
      emit(node, "number", .number(result))
      emit(node, "integer", .integer(Int(result)))
      emit(node, "boolean", .boolean(result != 0))
    case "image.scale":
      let image = try required(node, "image").image
      var width = try input(node, "width")?.integer ?? node.integer("width", default: 512)
      var height = try input(node, "height")?.integer ?? node.integer("height", default: 512)
      guard width >= 0, height >= 0, width <= 8192, height <= 8192 else {
        throw BaseTestSetError.invalid("Scaled image dimensions are out of range.")
      }
      if width == 0 && height == 0 { width = image.width; height = image.height }
      else if width == 0 {
        width = max(1, Int((Double(image.width) * Double(height) / Double(image.height)).rounded()))
      } else if height == 0 {
        height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
      }
      emit(node, "image", .image(try image.resized(to: width, height,
        method: node.string("upscaleMethod", default: "nearest-exact"),
        crop: node.string("crop", default: "disabled"))))
    case "image.scaleBy":
      let factor = try node.number("scaleBy", default: 1)
      guard factor.isFinite, factor > 0, factor <= 8192 else {
        throw BaseTestSetError.invalid("Scale factor must be positive and finite.")
      }
      let method = try node.string("upscaleMethod", default: "nearest-exact")
      let source = try required(node, "image")
      switch source {
      case .image(let image):
        emit(node, "image", .image(try image.resized(
          to: Int((Double(image.width) * factor).rounded()),
          Int((Double(image.height) * factor).rounded()), method: method)))
      case .imageBatch(let images):
        emit(node, "image", .imageBatch(try images.map { image in
          try image.resized(
            to: Int((Double(image.width) * factor).rounded()),
            Int((Double(image.height) * factor).rounded()), method: method)
        }))
      default: throw BaseTestSetError.invalid("Scale By expects an image or image batch.")
      }
    case "image.scaleToTotalPixels":
      let image = try required(node, "image").image
      let megapixels = try node.number("megapixels", default: 1)
      let resolution = try node.number("resolution", default: 1)
      guard megapixels.isFinite, megapixels > 0,
        resolution.isFinite, resolution >= 1,
        resolution <= 256, resolution.rounded() == resolution else {
        throw BaseTestSetError.invalid("Total-pixel scale requires positive megapixels and an integer resolution multiple.")
      }
      let multiple = Int(resolution)
      let scale = sqrt(megapixels * 1024 * 1024 / Double(image.width * image.height))
      let scaledWidth = Double(image.width) * scale
      let scaledHeight = Double(image.height) * scale
      guard scale.isFinite, scale > 0, scaledWidth.isFinite, scaledHeight.isFinite,
        scaledWidth <= 8192 + resolution / 2,
        scaledHeight <= 8192 + resolution / 2 else {
        throw BaseTestSetError.invalid("Total-pixel scale is out of range.")
      }
      let width = max(multiple, Int((scaledWidth / resolution).rounded()) * multiple)
      let height = max(multiple, Int((scaledHeight / resolution).rounded()) * multiple)
      emit(node, "image", .image(try image.resized(to: width, height,
        method: node.string("upscaleMethod", default: "nearest-exact"))))
    case "image.canny":
      let image = try required(node, "image").image
      emit(node, "image", .image(try image.canny(
        lowThreshold: node.number("lowThreshold", default: 0.4),
        highThreshold: node.number("highThreshold", default: 0.8))))
    case "image.crop":
      let image = try required(node, "image").image
      emit(node, "image", .image(try image.cropped(
        x: node.integer("x", default: 0), y: node.integer("y", default: 0),
        width: node.integer("width", default: 512),
        height: node.integer("height", default: 512))))
    case "image.invert":
      emit(node, "image", .image(try required(node, "image").image.invertedSRGB()))
    case "image.proceduralNoise":
      let result = try ProceduralArt.noise(
        seed: required(node, "seed").integer,
        width: node.integer("width", default: 512),
        height: node.integer("height", default: 512),
        scale: node.number("scale", default: 6),
        octaves: node.integer("octaves", default: 4),
        salt: node.integer("salt", default: 0),
        pattern: node.string("pattern", default: "smooth"),
        palette: node.string("palette", default: "aurora"))
      emit(node, "image", .image(result.image))
      emit(node, "height", .mask(result.height))
    case "image.sinusoid":
      let result = try ProceduralArt.sinusoid(
        width: node.integer("width", default: 960),
        height: node.integer("height", default: 600),
        cycles: node.number("cycles", default: 3),
        amplitude: node.number("amplitude", default: 0.25),
        phaseDegrees: node.number("phaseDegrees", default: 0),
        centerY: node.number("centerY", default: 0.5),
        strokeWidth: node.number("strokeWidth", default: 3),
        color: node.string("color", default: "red"),
        frequencyControl: input(node, "frequencyControl")?.number,
        amplitudeControl: input(node, "amplitudeControl")?.number)
      emit(node, "image", .image(result.image))
      emit(node, "mask", .mask(result.mask))
    case "signal.sinusoid":
      let wave = try ProceduralArt.makeSinusoid(
        cycles: node.number("cycles", default: 4),
        amplitude: node.number("amplitude", default: 0.25),
        phaseDegrees: node.number("phaseDegrees", default: 0),
        centerY: node.number("centerY", default: 0.5),
        frequencyControl: input(node, "frequencyControl")?.number,
        amplitudeControl: input(node, "amplitudeControl")?.number,
        phaseShiftDegrees: input(node, "phaseShiftDegrees")?.number)
      emit(node, "curve", .curve1D(.sinusoid(wave)))
    case "image.drawCurve":
      let curve = try required(node, "curve").curve1D
      let background = try input(node, "background")?.image
      let result = try ProceduralArt.drawCurve(
        curve: curve,
        background: background,
        width: node.integer("width", default: 960),
        height: node.integer("height", default: 600),
        strokeWidth: node.number("strokeWidth", default: 3),
        color: node.string("color", default: "red"),
        opacity: node.number("opacity", default: 1))
      emit(node, "image", .image(result.image))
      emit(node, "mask", .mask(result.mask))
    case "image.translate":
      let image = try required(node, "image").image
      let normalizedX = try input(node, "normalizedX")?.number
      let normalizedY = try input(node, "normalizedY")?.number
      guard [normalizedX, normalizedY].compactMap({ $0 }).allSatisfy({
        $0.isFinite && (0...1).contains($0)
      }) else { throw BaseTestSetError.invalid("Normalized translation must be between 0 and 1.") }
      let x = try normalizedX.map { Int((($0 - 0.5) * Double(image.width)).rounded()) }
        ?? input(node, "x")?.integer ?? node.integer("x", default: 0)
      let y = try normalizedY.map { Int((($0 - 0.5) * Double(image.height)).rounded()) }
        ?? input(node, "y")?.integer ?? node.integer("y", default: 0)
      emit(node, "image", .image(try ProceduralArt.translate(
        image, x: x, y: y, wrap: node.boolean("wrap", default: true))))
    case "image.blend":
      let a = try required(node, "imageA").image
      let b = try required(node, "imageB").image
      emit(node, "image", .image(try a.blendedSRGB(
        with: b, factor: input(node, "blendFactor")?.number
          ?? node.number("blendFactor", default: 0.5),
        mode: node.string("blendMode", default: "normal"))))
    case "image.batch":
      let first = try required(node, "imageA").images
      let second = try required(node, "imageB").images
      guard let reference = first.first else {
        throw BaseTestSetError.invalid("Image batch is empty.")
      }
      emit(node, "image", .imageBatch(first + (try second.map {
        try $0.resized(to: reference.width, reference.height,
          method: "bicubic", crop: "center")
      })))
    case "image.fromBatch":
      let images = try required(node, "image").imageBatch
      let start = try node.integer("batchIndex", default: 0)
      let length = try node.integer("length", default: 1)
      guard start >= 0, length > 0, start <= images.count,
        length <= images.count - start else {
        throw BaseTestSetError.invalid("Image batch selection is out of range.")
      }
      emit(node, "image", length == 1
        ? .image(images[start]) : .imageBatch(Array(images[start..<(start + length)])))
    case "image.compositeMasked":
      let x = try node.integer("x", default: 0)
      let y = try node.integer("y", default: 0)
      let resizeSource = try node.boolean("resizeSource", default: false)
      let destination = try required(node, "destination").image
      let source = try required(node, "source").image
      let mask = try input(node, "mask")?.mask
      emit(node, "image", .image(try destination.compositingSRGB(
        source, through: mask, x: x, y: y, resizeSource: resizeSource)))
    case "image.padForOutpaint":
      let image = try required(node, "image").image
      let pair = try image.padded(
        left: node.integer("left", default: 0),
        top: node.integer("top", default: 0),
        right: node.integer("right", default: 0),
        bottom: node.integer("bottom", default: 0),
        feathering: node.integer("feathering", default: 40))
      emit(node, "image", .image(pair.0))
      emit(node, "mask", .mask(pair.1))
    case "image.fillMasked":
      let image = try required(node, "image").image
      let mask = try required(node, "mask").mask
      emit(node, "image", .image(try image.fillingSRGB(
        mask: mask, value: node.number("value", default: 0.5))))
    case "mask.solid":
      let solidValue = try node.number("value", default: 1)
      guard solidValue.isFinite, (0...1).contains(solidValue) else {
        throw BaseTestSetError.invalid("Solid mask value must be between 0 and 1.")
      }
      emit(node, "mask", .mask(try BaseTestSetMask(
        width: node.integer("width", default: 512),
        height: node.integer("height", default: 512),
        value: Float(solidValue))))
    case "mask.radial":
      emit(node, "mask", .mask(try ProceduralArt.radialMask(
        width: node.integer("width", default: 512),
        height: node.integer("height", default: 512),
        centerX: input(node, "centerX")?.number ?? node.number("centerX", default: 0.5),
        centerY: input(node, "centerY")?.number ?? node.number("centerY", default: 0.5),
        radius: node.number("radius", default: 0.3),
        softness: node.number("softness", default: 0.15))))
    case "mask.stripes":
      emit(node, "mask", .mask(try ProceduralArt.stripeMask(
        width: node.integer("width", default: 512),
        height: node.integer("height", default: 512),
        count: node.integer("count", default: 12),
        duty: node.number("duty", default: 0.35),
        phase: input(node, "phase")?.number ?? node.number("phase", default: 0),
        orientation: node.string("orientation", default: "horizontal"))))
    case "mask.composite":
      let destination = try required(node, "destination").mask
      let source = try required(node, "source").mask
      let x = try node.integer("x", default: 0)
      let y = try node.integer("y", default: 0)
      emit(node, "mask", .mask(try destination.compositing(source, x: x, y: y,
        operation: node.string("operation", default: "multiply"))))
    case "mask.grow":
      let mask = try required(node, "mask").mask
      emit(node, "mask", .mask(try mask.grown(
        by: node.integer("expand", default: 0),
        taperedCorners: node.boolean("taperedCorners", default: true))))
    case "mask.feather":
      let mask = try required(node, "mask").mask
      emit(node, "mask", .mask(try mask.feathered(
        left: node.integer("left", default: 0),
        top: node.integer("top", default: 0),
        right: node.integer("right", default: 0),
        bottom: node.integer("bottom", default: 0))))
    case "mask.threshold":
      let mask = try required(node, "mask").mask
      let threshold = try input(node, "value")?.number ?? node.number("value", default: 0.5)
      guard threshold.isFinite, (0...1).contains(threshold) else {
        throw BaseTestSetError.invalid("Mask threshold must be between 0 and 1.")
      }
      emit(node, "mask", .mask(mask.thresholded(at: Float(threshold))))
    case "mask.fromImage":
      emit(node, "mask", .mask(try BaseTestSetMask(
        channel: node.string("channel", default: "red"),
        of: required(node, "image").image)))
    case "mask.crop":
      let mask = try required(node, "mask").mask
      emit(node, "mask", .mask(try mask.cropped(
        x: node.integer("x", default: 0), y: node.integer("y", default: 0),
        width: node.integer("width", default: 512),
        height: node.integer("height", default: 512))))
    case "mask.invert":
      emit(node, "mask", .mask(try required(node, "mask").mask.inverted()))
    case "mask.toImage":
      emit(node, "image", .image(try required(node, "mask").mask.image()))
    case "output.preview":
      let image = try required(node, "image").image
      emit(node, "image", .image(image))
      await progress(PipelineExecutionProgress(
        stage: .generating, message: "Preview: \(node.title ?? node.id.rawValue)",
        completedUnitCount: index + 1,
        totalUnitCount: nodeCount,
        preview: PipelineGeneratedImage(
          width: image.width, height: image.height,
          planarRGB: try image.planarRGB(),
          encoding: .sRGBZeroToOne,
          semanticPipelineSHA256: semanticSHA256, alpha: image.alpha),
        previewNodeID: nodeID,
        activeNodeIDs: [nodeID]))
    case "output.image":
      // Hosts install this executor over the built-in output.image executor.
      // Keep every loop-feedback field when converting the test-set image.
      let image = try required(node, "image").image
      let scenePlanJSON: String?
      if let saved = try input(node, "scenePlan")?.string {
        scenePlanJSON = try PipelineScenePlan.decode(saved).encodedJSON()
      } else {
        scenePlanJSON = nil
      }
      let feedbackText = try input(node, "feedbackText")?.string
      finalOutput = .image(PipelineGeneratedImage(
        width: image.width, height: image.height,
        planarRGB: try image.planarRGB(),
        encoding: .sRGBZeroToOne,
        semanticPipelineSHA256: semanticSHA256,
        alpha: image.alpha,
        scenePlanJSON: scenePlanJSON,
        feedbackText: feedbackText,
        nextStateJSON: try input(node, "nextState").map { try PipelineStateJSON.canonicalObject($0.string) }))

    case "input.video":
      let name = try node.string("sourceName")
      emit(node, "video", .video(try await BaseTestSetCodec.openVideo(at: sourceURL(
        name: name, root: sourceRoot))))
    case "input.audio":
      let name = try node.string("sourceName")
      let url = try sourceURL(name: name, root: sourceRoot)
      guard url.pathExtension.lowercased() == "wav" else {
        throw BaseTestSetError.invalid("This fixture runner supports WAV input only.")
      }
      emit(node, "audio", .audio(url))
    case "output.audio":
      let url = try required(node, "audio").audio
      finalOutput = .audio(PipelineGeneratedAudio(
        fileURL: url, semanticPipelineSHA256: semanticSHA256))
    case "media.videoComponents":
      var video = try required(node, "video").video
      if let sourceURL = video.sourceURL {
        video = try await BaseTestSetCodec.decodeVideo(at: sourceURL)
      }
      emit(node, "images", .imageBatch(video.frames))
      if let audio = video.audioSource { emit(node, "audio", .audio(audio)) }
      emit(node, "framesPerSecond", .number(video.framesPerSecond))
    case "output.videoPreview":
      let videoInput = input(node, "video")
      let imageInput = input(node, "image")
      guard (videoInput == nil) != (imageInput == nil) else {
        throw BaseTestSetError.invalid("Video Preview needs either Video or Image, not both.")
      }
      if let videoInput {
        let video = try videoInput.video
        let rawIndex = try input(node, "frameIndex")?.number
          ?? Double(try invocation.integer(for: PipelineInvocation.loopCallIndexKey,
            default: 0))
        guard rawIndex.isFinite, rawIndex >= 0, rawIndex.rounded() == rawIndex,
          rawIndex <= Double(Int.max) else {
          throw BaseTestSetError.invalid("Video Preview frameIndex must be a non-negative integer.")
        }
        let frame = try await BaseTestSetCodec.frame(Int(rawIndex), from: video)
        emit(node, "video", .video(video))
        emit(node, "image", .image(frame))
        let playableURL: URL
        if let sourceURL = video.sourceURL {
          playableURL = sourceURL
        } else {
          playableURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pixeltje-preview-\(UUID().uuidString.lowercased()).mp4")
          try await BaseTestSetCodec.encodeVideo(video, to: playableURL)
        }
        await progress(.init(stage: .generating,
          message: "Video frame \(Int(rawIndex) + 1)/\(video.frameCount)",
          completedUnitCount: index + 1, totalUnitCount: nodeCount,
          previewVideoURL: playableURL, previewVideoNodeID: nodeID,
          previewVideoIsTemporary: video.sourceURL == nil,
          activeNodeIDs: [nodeID]))
      } else if let imageInput {
        let image = try imageInput.image
        let frameRate = try node.number("framesPerSecond", default: 30)
        guard frameRate.isFinite, frameRate > 0, frameRate <= 240 else {
          throw BaseTestSetError.invalid("Video Preview frame rate must be greater than 0 and at most 240.")
        }
        emit(node, "image", .image(image))
        await progress(.init(stage: .generating,
          message: "Video Preview: \(node.title ?? node.id.rawValue)",
          completedUnitCount: index + 1, totalUnitCount: nodeCount,
          preview: PipelineGeneratedImage(width: image.width, height: image.height,
            planarRGB: try image.planarRGB(), encoding: .sRGBZeroToOne,
            semanticPipelineSHA256: semanticSHA256, alpha: image.alpha),
          previewNodeID: nodeID, previewFramesPerSecond: frameRate,
          activeNodeIDs: [nodeID]))
      }
    case "utility.reroute":
      emit(node, "value", try required(node, "value"))
    case "utility.previewAny":
      emit(node, "text", .string(input(node, "value").map {
        BaseTestSetScalarOperations.preview($0)
      } ?? ""))
    case "media.createVideo":
      let images = try required(node, "images").imageBatch
      let audio = try input(node, "audio")?.audio
      let frameRate = try node.number("framesPerSecond", default: 30)
      guard try node.string("codec", default: "none") == "h264" else {
        throw BaseTestSetError.invalid("This fixture runner supports H.264 video only.")
      }
      let bitDepth = node.parameters["bitDepth"] ?? .string("auto")
      guard bitDepth == .string("auto") || bitDepth == .integer(8),
        try node.string("colorSpace", default: "sRGB") == "sRGB" else {
        throw BaseTestSetError.invalid("H.264 video supports 8-bit sRGB input only.")
      }
      emit(node, "video", .video(BaseTestSetVideo(
        frames: images, audioSource: audio, framesPerSecond: frameRate)))
    case "output.video":
      guard try node.string("codec", default: "h264") == "h264",
        try node.string("format", default: "mp4") == "mp4" else {
        throw BaseTestSetError.invalid("Video output supports H.264 in MP4 only.")
      }
      if let imageValue = input(node, "image") {
        guard input(node, "video") == nil else {
          throw BaseTestSetError.invalid("Video Output accepts either Image or Video, not both.")
        }
        let image = try imageValue.image
        let framesPerSecond = try input(node, "framesPerSecond")?.number
          ?? node.number("framesPerSecond", default: 30)
        guard framesPerSecond.isFinite, framesPerSecond > 0,
          framesPerSecond <= 240 else {
          throw BaseTestSetError.invalid("Video frame rate must be greater than 0 and at most 240.")
        }
        finalOutput = .videoFrame(PipelineVideoFrame(image: PipelineGeneratedImage(
          width: image.width, height: image.height,
          planarRGB: try image.planarRGB(), encoding: .sRGBZeroToOne,
          semanticPipelineSHA256: semanticSHA256, alpha: image.alpha),
          framesPerSecond: framesPerSecond))
        break
      }
      let video = try required(node, "video").video
      if let sourceURL = video.sourceURL {
        finalOutput = .video(PipelineGeneratedVideo(
          fileURL: sourceURL, width: video.width, height: video.height,
          frameCount: video.frameCount, framesPerSecond: video.framesPerSecond,
          semanticPipelineSHA256: semanticSHA256))
        break
      }
      guard let first = video.frames.first else {
        throw BaseTestSetError.invalid("Video has no frames.")
      }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pixeltje-base-test-set-\(UUID().uuidString).mp4")
      try await BaseTestSetCodec.encodeVideo(video, to: url)
      finalOutput = .video(PipelineGeneratedVideo(
        fileURL: url, width: first.width, height: first.height,
        frameCount: video.frames.count, framesPerSecond: video.framesPerSecond,
        semanticPipelineSHA256: semanticSHA256))
    case "diffusion.karrasScheduler":
      emit(node, "schedule", .schedule(try PipelineSigmaSchedules.karras(
        steps: node.integer("steps", default: 20),
        sigmaMin: node.number("sigmaMin", default: 0.0291675),
        sigmaMax: node.number("sigmaMax", default: 14.614642),
        rho: node.number("rho", default: 7))))
    case "diffusion.exponentialScheduler":
      emit(node, "schedule", .schedule(try PipelineSigmaSchedules.exponential(
        steps: node.integer("steps", default: 20),
        sigmaMin: node.number("sigmaMin", default: 0.0291675),
        sigmaMax: node.number("sigmaMax", default: 14.614642))))
    case "diffusion.alignYourStepsScheduler":
      let modelType = try node.string("modelType", default: "SDXL")
      guard let model = PipelineSigmaSchedules.AlignYourStepsModel(rawValue: modelType) else {
        throw BaseTestSetError.invalid("Unsupported Align Your Steps model type \(modelType).")
      }
      emit(node, "schedule", .schedule(try PipelineSigmaSchedules.alignYourSteps(
        model: model, steps: node.integer("steps", default: 10),
        denoise: node.number("denoise", default: 1))))
    case "diffusion.splitSchedule":
      let halves = try PipelineSigmaSchedules.split(
        required(node, "schedule").schedule, atStep: node.integer("step", default: 0))
      emit(node, "high", .schedule(halves.high))
      emit(node, "low", .schedule(halves.low))
    case "diffusion.splitScheduleDenoise":
      let halves = try PipelineSigmaSchedules.split(
        required(node, "schedule").schedule, denoise: node.number("denoise", default: 1))
      emit(node, "high", .schedule(halves.high))
      emit(node, "low", .schedule(halves.low))
    case "diffusion.flipSchedule":
      emit(node, "schedule", .schedule(PipelineSigmaSchedules.flipped(
        try required(node, "schedule").schedule)))
    case "diffusion.forceFullDenoise":
      emit(node, "schedule", .schedule(PipelineSigmaSchedules.denoisedToZero(
        try required(node, "schedule").schedule)))
    case "latent.disableNoise":
      emit(node, "noise", .noise("disabled"))
    case "latent.randomNoise":
      guard case .integer(let seed)? = node.parameters["seed"], seed >= 0 else {
        throw BaseTestSetError.invalid("Random Noise needs a non-negative integer seed.")
      }
      emit(node, "noise", .noise("seed \(seed)"))
    case "diffusion.samplerSelector":
      let name = try node.string("samplerName")
      guard !name.isEmpty else { throw BaseTestSetError.invalid("Sampler name is empty.") }
      emit(node, "function", .sampler(name))
    case "diffusion.lcmSampler":
      let stepNoise = try node.number("stepNoise", default: 1)
      let endStepNoise = try node.number("endStepNoise", default: 1)
      let clip = try node.number("noiseClipStandardDeviations", default: 0)
      guard stepNoise.isFinite, endStepNoise.isFinite, clip.isFinite, clip >= 0 else {
        throw BaseTestSetError.invalid("LCM Sampler noise settings must be finite.")
      }
      emit(node, "function", .sampler("lcm"))
    case "latent.emptyImage", "latent.emptyFlux2Image":
      let width = try input(node, "width")?.integer ?? node.integer("width", default: 1024)
      let height = try input(node, "height")?.integer ?? node.integer("height", default: 1024)
      let batchSize = try node.integer("batchSize", default: 1)
      emit(node, "latent", .latent(try node.kind.rawValue == "latent.emptyImage"
        ? PipelineLatent.emptyImage(width: width, height: height, batchSize: batchSize)
        : PipelineLatent.emptyFLUX2Image(width: width, height: height, batchSize: batchSize)))
    case "latent.emptyHunyuanVideo", "latent.emptyLTXVVideo":
      let isHunyuan = node.kind.rawValue == "latent.emptyHunyuanVideo"
      let width = try input(node, "width")?.integer
        ?? node.integer("width", default: isHunyuan ? 848 : 768)
      let height = try input(node, "height")?.integer
        ?? node.integer("height", default: isHunyuan ? 480 : 512)
      let length = try input(node, "length")?.integer
        ?? node.integer("length", default: isHunyuan ? 25 : 97)
      let batchSize = try node.integer("batchSize", default: 1)
      emit(node, "latent", .latent(try isHunyuan
        ? PipelineLatent.emptyHunyuanVideo(
          width: width, height: height, length: length, batchSize: batchSize)
        : PipelineLatent.emptyLTXVVideo(
          width: width, height: height, length: length, batchSize: batchSize)))
    case "latent.zerosLike":
      emit(node, "latent", .latent(try required(node, "latent").latent.zerosLike()))
    case "latent.repeatBatch":
      emit(node, "latent", .latent(try required(node, "latent").latent.repeated(
        node.integer("amount", default: 1))))
    case "latent.fromBatch":
      emit(node, "latent", .latent(try required(node, "latent").latent.selectingBatch(
        from: node.integer("batchIndex", default: 0),
        length: node.integer("length", default: 1))))
    case "latent.upscale":
      let latent = try required(node, "latent").latent
      let size = try BaseTestSetScalarOperations.latentUpscaleSize(
        of: latent,
        width: input(node, "width")?.integer ?? node.integer("width", default: 512),
        height: input(node, "height")?.integer ?? node.integer("height", default: 512))
      let method = try node.string("upscaleMethod", default: "nearest-exact")
      let crop = try node.string("crop", default: "disabled")
      emit(node, "latent", .latent(try size.map {
        try latent.resized(width: $0.width, height: $0.height, method: method, crop: crop)
      } ?? latent))
    case "latent.upscaleBy":
      let latent = try required(node, "latent").latent
      let factor = try node.number("scaleBy", default: 1.5)
      guard factor.isFinite, (0.01...8).contains(factor) else {
        throw BaseTestSetError.invalid("Latent scale factor must be 0.01–8.")
      }
      emit(node, "latent", .latent(try latent.resized(
        width: Int((Double(latent.width) * factor).rounded(.toNearestOrEven)),
        height: Int((Double(latent.height) * factor).rounded(.toNearestOrEven)),
        method: node.string("upscaleMethod", default: "nearest-exact"))))
    case "latent.setNoiseMask":
      var latent = try required(node, "latent").latent
      let mask = try required(node, "mask").mask
      latent.noiseMask = try PipelineLatentNoiseMask(
        width: mask.width, height: mask.height,
        coverage: mask.values.map { min(max($0, 0), 1) })
      emit(node, "latent", .latent(latent))
    default:
      throw BaseTestSetError.invalid("Node \(node.kind.rawValue) has no Base Test Set implementation.")
    }
    return BaseTestNodeResult(outputs: outputs, terminalOutput: finalOutput)
  }

  private static func sourceURL(name: String, root: URL?) throws -> URL {
    guard let root else { throw BaseTestSetError.invalid("Select a source media folder.") }
    guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
      name != ".", name != ".."
    else { throw BaseTestSetError.invalid("Source name must be a filename in the source directory.") }
    let url = root.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw BaseTestSetError.invalid("Source \(name) is missing from \(root.path).")
    }
    return url
  }

}

private extension Value {
  var portType: PipelinePortType {
    switch self {
    case .string: .string
    case .integer: .integer
    case .number: .number
    case .curve1D: .curve1D
    case .mesh3D: .mesh3D
    case .matrix4x4: .matrix4x4
    case .boolean: .boolean
    case .image, .imageBatch: .image
    case .mask: .mask
    case .audio: .audio
    case .video: .video
    case .schedule: .schedule
    case .latent: .latent
    case .noise: .noise
    case .sampler: .samplerFunction
    }
  }

  static func from(_ wrapped: PipelineNodeValue) throws -> Value {
    if let value = wrapped.value(as: Value.self) { return value }
    switch wrapped.type {
    case .string, .prompt:
      if let value = wrapped.value(as: String.self) { return .string(value) }
    case .integer, .seed:
      if let value = wrapped.value(as: Int.self) { return .integer(value) }
      if let value = wrapped.value(as: Int64.self), let integer = Int(exactly: value) {
        return .integer(integer)
      }
      if let value = wrapped.value(as: UInt64.self), let integer = Int(exactly: value) {
        return .integer(integer)
      }
    case .number:
      if let value = wrapped.value(as: Double.self) { return .number(value) }
    case .boolean:
      if let value = wrapped.value(as: Bool.self) { return .boolean(value) }
    case .mesh3D:
      if let value = wrapped.value(as: PipelineMesh3D.self) { return .mesh3D(value) }
    case .matrix4x4:
      if let value = wrapped.value(as: PipelineMatrix4x4.self) { return .matrix4x4(value) }
    case .image:
      if let image = wrapped.value(as: PipelineImageInput.self) {
        return .image(try BaseTestSetImage(
          width: image.width, height: image.height, rgba: image.rgba))
      }
      if let image = wrapped.value(as: PipelineGeneratedImage.self) {
        try BaseTestSetImage.validateDimensions(width: image.width, height: image.height)
        let pixels = image.width * image.height
        guard image.planarRGB.count == pixels * 3,
          image.alpha.map({ $0.count == pixels && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) ?? true else {
          throw BaseTestSetError.invalid("Generated image pixels are incomplete.")
        }
        var rgba = [Float](repeating: 1, count: pixels * 4)
        for pixel in 0..<pixels {
          let alpha = image.alpha?[pixel] ?? 1
          rgba[pixel * 4 + 3] = alpha
          for channel in 0..<3 {
            rgba[pixel * 4 + channel] = image.encoding.normalizedSRGBComponent(
              from: image.planarRGB[channel * pixels + pixel]) * alpha
          }
        }
        return .image(try BaseTestSetImage(
          width: image.width, height: image.height, rgba: rgba))
      }
    case .mask:
      if let mask = wrapped.value(as: PipelineMaskInput.self) {
        return .mask(try BaseTestSetMask(host: mask))
      }
    case .latent:
      if let latent = wrapped.value(as: PipelineLatent.self) { return .latent(latent) }
    case .schedule:
      if let schedule = wrapped.value(as: [Double].self) { return .schedule(schedule) }
    default: break
    }
    throw BaseTestSetError.invalid(
      "No native value bridge is installed for \(wrapped.type.rawValue).")
  }

  var string: String {
    get throws {
      guard case .string(let value) = self else {
        throw BaseTestSetError.invalid("Expected a text value.")
      }
      return value
    }
  }
  var integer: Int {
    get throws {
      guard case .integer(let value) = self else {
        throw BaseTestSetError.invalid("Expected an integer value.")
      }
      return value
    }
  }
  var number: Double {
    get throws {
      switch self {
      case .number(let value): return value
      case .integer(let value): return Double(value)
      default: throw BaseTestSetError.invalid("Expected a numeric value.")
      }
    }
  }
  var curve1D: ProceduralArt.Curve1D {
    get throws {
      guard case .curve1D(let value) = self else {
        throw BaseTestSetError.invalid("Expected a curve value.")
      }
      return value
    }
  }
  var boolean: Bool {
    get throws {
      guard case .boolean(let value) = self else {
        throw BaseTestSetError.invalid("Expected a Boolean value.")
      }
      return value
    }
  }
  var image: BaseTestSetImage {
    get throws {
      guard case .image(let value) = self else {
        throw BaseTestSetError.invalid("Expected an image value.")
      }
      return value
    }
  }
  var imageBatch: [BaseTestSetImage] {
    get throws {
      guard case .imageBatch(let value) = self else {
        throw BaseTestSetError.invalid("Expected an image batch.")
      }
      return value
    }
  }
  var images: [BaseTestSetImage] {
    get throws {
      switch self {
      case .image(let value): return [value]
      case .imageBatch(let values): return values
      default: throw BaseTestSetError.invalid("Expected an image or image batch.")
      }
    }
  }
  var mask: BaseTestSetMask {
    get throws {
      guard case .mask(let value) = self else {
        throw BaseTestSetError.invalid("Expected a mask value.")
      }
      return value
    }
  }
  var audio: URL {
    get throws {
      guard case .audio(let value) = self else {
        throw BaseTestSetError.invalid("Expected an audio value.")
      }
      return value
    }
  }
  var video: BaseTestSetVideo {
    get throws {
      guard case .video(let value) = self else {
        throw BaseTestSetError.invalid("Expected a video value.")
      }
      return value
    }
  }
  var schedule: [Double] {
    get throws {
      guard case .schedule(let value) = self else {
        throw BaseTestSetError.invalid("Expected a schedule value.")
      }
      return value
    }
  }
  var latent: PipelineLatent {
    get throws {
      guard case .latent(let value) = self else {
        throw BaseTestSetError.invalid("Expected a latent value.")
      }
      return value
    }
  }
}

private extension PipelineNode {
  func string(_ name: String, default defaultValue: String? = nil) throws -> String {
    guard let value = parameters[name] else {
      if let defaultValue { return defaultValue }
      throw BaseTestSetError.invalid("\(id.rawValue) is missing \(name).")
    }
    guard case .string(let result) = value else {
      throw BaseTestSetError.invalid("\(id.rawValue).\(name) must be text.")
    }
    return result
  }
  func integer(_ name: String, default defaultValue: Int) throws -> Int {
    guard let value = parameters[name] else { return defaultValue }
    guard case .integer(let result) = value, let exact = Int(exactly: result) else {
      throw BaseTestSetError.invalid("\(id.rawValue).\(name) must be an integer.")
    }
    return exact
  }
  func number(_ name: String, default defaultValue: Double) throws -> Double {
    guard let value = parameters[name] else { return defaultValue }
    switch value {
    case .number(let result): return result
    case .integer(let result): return Double(result)
    default: throw BaseTestSetError.invalid("\(id.rawValue).\(name) must be numeric.")
    }
  }
  func boolean(_ name: String, default defaultValue: Bool) throws -> Bool {
    guard let value = parameters[name] else { return defaultValue }
    guard case .boolean(let result) = value else {
      throw BaseTestSetError.invalid("\(id.rawValue).\(name) must be Boolean.")
    }
    return result
  }
}

private enum BaseTestSetScalarOperations {
  static func resolution(
    aspectRatio: String, megapixels: Double, multiple: Int
  ) throws -> (width: Int, height: Int) {
    let ratio: (Double, Double)
    switch aspectRatio {
    case "1:1 (Square)": ratio = (1, 1)
    case "2:3 (Portrait Photo)": ratio = (2, 3)
    case "3:2 (Photo)": ratio = (3, 2)
    case "3:4 (Portrait Standard)": ratio = (3, 4)
    case "4:3 (Standard)": ratio = (4, 3)
    case "9:16 (Portrait Widescreen)": ratio = (9, 16)
    case "16:9 (Widescreen)": ratio = (16, 9)
    case "21:9 (Ultrawide)": ratio = (21, 9)
    default: throw BaseTestSetError.invalid("Unsupported resolution aspect ratio \(aspectRatio).")
    }
    guard megapixels.isFinite, (0.1...16).contains(megapixels),
      (8...128).contains(multiple), multiple.isMultiple(of: 4)
    else {
      throw BaseTestSetError.invalid("Resolution requires 0.1–16 megapixels and an alignment of 8–128 in steps of 4.")
    }
    let scale = sqrt(megapixels * 1024 * 1024 / (ratio.0 * ratio.1))
    let width = Int((ratio.0 * scale / Double(multiple)).rounded(.toNearestOrEven)) * multiple
    let height = Int((ratio.1 * scale / Double(multiple)).rounded(.toNearestOrEven)) * multiple
    guard (1...8192).contains(width), (1...8192).contains(height) else {
      throw BaseTestSetError.invalid("Calculated resolution is outside the supported image range.")
    }
    return (width, height)
  }

  static func replacing(_ value: String, find: String, with replacement: String) -> String {
    guard !find.isEmpty else {
      guard !value.isEmpty else { return replacement }
      return replacement + value.unicodeScalars.map(String.init).joined(separator: replacement)
        + replacement
    }
    return value.replacingOccurrences(of: find, with: replacement)
  }

  static func substring(_ value: String, start: Int, end: Int) -> String {
    let scalars = Array(value.unicodeScalars)
    func offset(_ index: Int) -> Int {
      if index < 0 {
        return index < -scalars.count ? 0 : scalars.count + index
      }
      return min(index, scalars.count)
    }
    let lower = offset(start)
    let upper = offset(end)
    guard lower < upper else { return "" }
    return scalars[lower..<upper].map(String.init).joined()
  }

  static func extract(
    from value: String, matches: [NSTextCheckingResult], mode: String, groupIndex: Int
  ) throws -> String {
    guard (0...100).contains(groupIndex) else {
      throw BaseTestSetError.invalid("Regex group index must be between 0 and 100.")
    }
    func capture(_ match: NSTextCheckingResult, at index: Int) -> String {
      guard index < match.numberOfRanges,
        let range = Range(match.range(at: index), in: value)
      else { return "" }
      return String(value[range])
    }
    switch mode {
    case "First Match":
      return matches.first.map { capture($0, at: 0) } ?? ""
    case "All Matches":
      return matches.map { capture($0, at: $0.numberOfRanges > 1 ? 1 : 0) }
        .joined(separator: "\n")
    case "First Group":
      return matches.first.map { capture($0, at: groupIndex) } ?? ""
    case "All Groups":
      return matches.filter { $0.numberOfRanges > 1 && groupIndex < $0.numberOfRanges }
        .map { capture($0, at: groupIndex) }.joined(separator: "\n")
    default:
      throw BaseTestSetError.invalid("Unsupported regex extraction mode \(mode).")
    }
  }

  static func preview(_ value: Value) -> String {
    switch value {
    case .string(let text): return text
    case .integer(let number): return String(number)
    case .number(let number): return String(number)
    case .curve1D(let curve): return curve.summary
    case .mesh3D(let mesh): return mesh.pipelineTraceValue().summary
    case .matrix4x4(let matrix): return matrix.pipelineTraceValue().summary
    case .boolean(let value): return value ? "True" : "False"
    case .image(let image): return "Image \(image.width)×\(image.height)"
    case .imageBatch(let images): return "Image batch (\(images.count) frames)"
    case .mask(let mask): return "Mask \(mask.width)×\(mask.height)"
    case .audio: return "Audio"
    case .video(let video): return "Video (\(video.frames.count) frames)"
    case .schedule(let sigmas):
      return "[" + sigmas.map { String(format: "%.6g", $0) }.joined(separator: ", ") + "]"
    case .latent(let latent):
      let shape = latent.shape.map { $0.map(String.init) ?? "model channels" }
      return "Latent [\(shape.joined(separator: ", "))]"
        + (latent.noiseMask == nil ? "" : " with noise mask")
    case .noise(let description): return "Noise (\(description))"
    case .sampler(let name): return "Sampler \(name)"
    }
  }

  /// Upscale Latent's target in latent cells, or nil to keep the latent. As
  /// in ComfyUI, a zero side follows the source aspect ratio and each side is
  /// at least 64 pixels. Pixels convert at the latent's own spatial scale.
  static func latentUpscaleSize(
    of latent: PipelineLatent, width: Int, height: Int
  ) throws -> (width: Int, height: Int)? {
    guard (0...16384).contains(width), (0...16384).contains(height) else {
      throw BaseTestSetError.invalid("Latent upscale dimensions must be 0–16384 pixels.")
    }
    if width == 0 && height == 0 { return nil }
    var pixelWidth = max(64, width)
    var pixelHeight = max(64, height)
    if width == 0 {
      pixelWidth = max(64, Int((Double(latent.width) * Double(pixelHeight)
        / Double(latent.height)).rounded(.toNearestOrEven)))
    } else if height == 0 {
      pixelHeight = max(64, Int((Double(latent.height) * Double(pixelWidth)
        / Double(latent.width)).rounded(.toNearestOrEven)))
    }
    return (pixelWidth / latent.spatialScale, pixelHeight / latent.spatialScale)
  }
}
