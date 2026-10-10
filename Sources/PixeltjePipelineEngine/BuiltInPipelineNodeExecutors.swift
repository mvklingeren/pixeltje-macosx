import Foundation
import PixeltjePipelineDomain

enum BuiltInPipelineNodeExecutors {
  static let all: [PipelineNodeExecutor] = [
    PipelineNodeExecutor(kind: .controlStart) { _, _, _ in PipelineNodeResult() },
    PipelineNodeExecutor(kind: .controlLoop) { _, _, context in
      let callIndex = try context.invocation.integer(
        for: PipelineInvocation.loopCallIndexKey, default: 0)
      guard callIndex >= 0 else {
        throw PipelineEngineError.invalidInvocation("Loop call index must be non-negative.")
      }
      return PipelineNodeResult(outputs: [
        "callIndex": PipelineNodeValue(Double(callIndex), type: .number)
      ])
    },
    PipelineNodeExecutor(kind: .controlTimeline) { node, inputs, context in
      guard let settings = PipelineTimelineSettings(node: node),
        let input = inputs["value"] else {
        throw PipelineEngineError.invalidInvocation("Timeline needs valid keyframes and an input value.")
      }
      let frame = try context.invocation.integer(
        for: PipelineInvocation.loopCallIndexKey, default: 0)
      guard frame >= 0 else {
        throw PipelineEngineError.invalidInvocation("Timeline frame must be non-negative.")
      }
      let sampledFrame = min(Int(frame), settings.frameCount - 1)
      let animated: PipelineNodeValue
      if settings.tracks.isEmpty {
        animated = input
      } else {
        switch input.type {
        case .integer:
          guard let track = settings.tracks.first,
            settings.tracks.count == 1, track.path == "" else {
            throw PipelineEngineError.invalidInvocation("An integer Timeline needs one scalar track.")
          }
          let value = track.value(at: sampledFrame)
          if case .integer(let integer) = value {
            animated = PipelineNodeValue(integer, type: .integer)
          } else {
            guard case .number(let number) = value,
              number.isFinite, number >= Double(Int64.min),
              number < Double(Int64.max) else {
              throw PipelineEngineError.invalidInvocation("Timeline integer is out of range.")
            }
            animated = PipelineNodeValue(Int64(number.rounded()), type: .integer)
          }
        case .number:
          guard let track = settings.tracks.first,
            settings.tracks.count == 1, track.path == "" else {
            throw PipelineEngineError.invalidInvocation("A number Timeline needs one scalar track.")
          }
          let number: Double = switch track.value(at: sampledFrame) {
          case .integer(let integer): Double(integer)
          case .number(let number): number
          default: throw PipelineEngineError.invalidInvocation("A number Timeline needs numeric keyframes.")
          }
          guard number.isFinite else {
            throw PipelineEngineError.invalidInvocation("Timeline number must be finite.")
          }
          animated = PipelineNodeValue(number, type: .number)
        case .string:
          guard let original = input.value(as: String.self) else {
            throw PipelineEngineError.invalidInvocation("Timeline state input has no string value.")
          }
          animated = PipelineNodeValue(
            try settings.state(original, at: sampledFrame), type: .string)
        default:
          throw PipelineEngineError.invalidInvocation(
            "Timeline supports integer, number, and JSON state string keyframes.")
        }
      }
      return PipelineNodeResult(outputs: [
        "value": animated,
        "frameIndex": PipelineNodeValue(frame, type: .integer),
        "timeSeconds": PipelineNodeValue(Double(frame) / settings.framesPerSecond, type: .number),
        "progress": PipelineNodeValue(settings.frameCount == 1 ? 0 :
          Double(sampledFrame) / Double(settings.frameCount - 1), type: .number),
        "framesPerSecond": PipelineNodeValue(settings.framesPerSecond, type: .number),
      ])
    },
    PipelineNodeExecutor(kind: .promptInput) { node, _, context in
      let prompt = try context.invocation.string(
        for: PipelineInvocation.promptKey,
        default: node.parameters["value"]?.stringValue ?? "")
      return PipelineNodeResult(outputs: [
        "prompt": PipelineNodeValue(prompt, type: .prompt)
      ])
    },
    PipelineNodeExecutor(kind: .negativePromptInput) { node, _, context in
      let prompt = try context.invocation.string(
        for: PipelineInvocation.negativePromptKey,
        default: node.parameters["value"]?.stringValue ?? "")
      return PipelineNodeResult(outputs: [
        "prompt": PipelineNodeValue(prompt, type: .prompt)
      ])
    },
    PipelineNodeExecutor(kind: .primitiveFilePath,
      validate: PipelineFilePath.diagnostics) { node, _, context in
      var outputs: [String: PipelineNodeValue] = [
        "value": PipelineNodeValue(try PipelineFilePath.value(from: node), type: .string)
      ]
      if context.requestedOutputPorts?.contains("contents") ?? true {
        outputs["contents"] = PipelineNodeValue(
          try PipelineFilePath.contents(from: node, sourceRoot: context.sourceMediaRoot),
          type: .string)
      }
      return PipelineNodeResult(outputs: outputs)
    },
    PipelineNodeExecutor(kind: .seedInput) { node, _, context in
      let fallback: UInt64
      if case .integer(let saved)? = node.parameters["value"], saved >= 0 {
        fallback = UInt64(saved)
      } else {
        fallback = 0
      }
      let mode = node.parameters["mode"]?.stringValue ?? "fixed"
      guard mode == "fixed" || mode == "random" else {
        throw PipelineEngineError.invalidInvocation(
          "Seed mode must be fixed or random.")
      }
      let defaultSeed: UInt64 = mode == "random"
        ? UInt64.random(in: 0...UInt64(UInt32.max)) : fallback
      let seed = try context.invocation.unsignedInteger(
        for: PipelineInvocation.seedKey, default: defaultSeed)
      return PipelineNodeResult(outputs: [
        "seed": PipelineNodeValue(seed, type: .seed)
      ])
    },
    PipelineNodeExecutor(kind: .trackpad) { node, _, context in
      func coordinate(_ name: String, key: String) throws -> Double {
        let value = try context.invocation.number(
          for: key, default: node.parameters[name]?.numberValue ?? 0.5)
        guard value.isFinite else {
          throw PipelineEngineError.invalidInvocation(
            "Trackpad \(name) must be a finite number.")
        }
        return min(max(value, 0), 1)
      }
      let savedEngaged: Bool = if case .boolean(let value)? = node.parameters["engaged"] {
        value
      } else {
        false
      }
      let engaged: Bool
      if let override = context.invocation[PipelineInvocation.trackpadEngagedKey] {
        guard case .boolean(let value) = override else {
          throw PipelineEngineError.invalidInvocation(
            "Trackpad engaged must be a boolean.")
        }
        engaged = value
      } else {
        engaged = savedEngaged
      }
      let engagedAtCall = try context.invocation.integer(
        for: PipelineInvocation.trackpadEngagedAtCallKey,
        default: Int(node.parameters["engagedAtCall"]?.integerValue ?? 0))
      guard engagedAtCall >= 0 else {
        throw PipelineEngineError.invalidInvocation(
          "Trackpad engagedAtCall must be non-negative.")
      }
      let actionCount = try context.invocation.integer(
        for: PipelineInvocation.trackpadActionCountKey, default: 0)
      guard (0...16_777_215).contains(actionCount) else {
        throw PipelineEngineError.invalidInvocation(
          "Trackpad action count must be between 0 and 16,777,215.")
      }
      return PipelineNodeResult(outputs: [
        "x": PipelineNodeValue(try coordinate("x", key: PipelineInvocation.trackpadXKey),
          type: .number),
        "y": PipelineNodeValue(try coordinate("y", key: PipelineInvocation.trackpadYKey),
          type: .number),
        "engaged": PipelineNodeValue(engaged, type: .boolean),
        "engagedAtCall": PipelineNodeValue(Double(engagedAtCall), type: .number),
        "actionCount": PipelineNodeValue(Double(actionCount), type: .number),
      ])
    },
    PipelineNodeExecutor(kind: .textSplit) { node, inputs, _ in
      guard let source = inputs["text"]?.value(as: String.self) else {
        throw PipelineEngineError.invalidInvocation("Split Text needs text input.")
      }
      let separator = node.parameters["separator"]?.stringValue ?? "|"
      let maxItems = node.parameters["maxItems"]?.integerValue ?? 8
      guard !separator.isEmpty, (1...64).contains(maxItems) else {
        throw PipelineEngineError.invalidInvocation(
          "Split Text needs a nonempty separator and 1–64 maximum items.")
      }
      let trimItems: Bool = if case .boolean(let value)? = node.parameters["trimItems"] {
        value
      } else { true }
      let omitEmpty: Bool = if case .boolean(let value)? = node.parameters["omitEmpty"] {
        value
      } else { true }
      var items = source.components(separatedBy: separator)
      if trimItems { items = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
      if omitEmpty { items.removeAll(where: \.isEmpty) }
      return PipelineNodeResult(outputs: [
        "items": PipelineNodeValue(Array(items.prefix(Int(maxItems))), type: .stringList)
      ])
    },
    PipelineNodeExecutor(kind: .maskHitTest) { node, inputs, _ in
      guard let masks = inputs["masks"]?.value(as: [PipelineLabeledMask].self),
        let x = inputs["x"]?.value(as: Double.self),
        let y = inputs["y"]?.value(as: Double.self)
      else {
        throw PipelineEngineError.invalidInvocation(
          "Mask Hit Test needs labeled masks and Trackpad X/Y.")
      }
      let threshold = node.parameters["coverageThreshold"]?.numberValue ?? 0.5
      let radius = node.parameters["radiusPixels"]?.integerValue ?? 2
      guard threshold.isFinite, threshold > 0, threshold <= 1,
        (0...16).contains(radius) else {
        throw PipelineEngineError.invalidInvocation(
          "Mask Hit Test needs a threshold in (0,1] and radius of 0–16 pixels.")
      }
      let selected = try PipelineMaskHitTest.pick(
        masks: masks, x: x, y: y, threshold: Float(threshold), radius: Int(radius))
      var outputs: [String: PipelineNodeValue] = [
        "found": PipelineNodeValue(selected != nil, type: .boolean),
        "label": PipelineNodeValue(selected?.label ?? "", type: .string),
        "score": PipelineNodeValue(Double(selected?.score ?? 0), type: .number),
      ]
      if let selected {
        outputs["mask"] = PipelineNodeValue(selected.mask, type: .mask)
      }
      return PipelineNodeResult(outputs: outputs)
    },
    PipelineNodeExecutor(kind: .previousScenePlanInput) { _, _, context in
      let plan = try context.invocation.string(
        for: PipelineInvocation.previousScenePlanKey, default: "")
      return PipelineNodeResult(outputs: [
        "scenePlan": PipelineNodeValue(plan, type: .string)
      ])
    },
    PipelineNodeExecutor(kind: .previousFrameInput) { _, _, context in
      var masks: [PipelineLabeledMask] = []
      if let supplied = context.invocation[PipelineInvocation.interactionMasksKey] {
        guard case .labeledMasks(let suppliedMasks) = supplied else {
          throw PipelineEngineError.invalidInvocation("Previous Frame needs labeled interaction masks.")
        }
        masks = suppliedMasks
      }
      var outputs = ["masks": PipelineNodeValue(masks, type: .labeledMasks)]
      guard let value = context.invocation[PipelineInvocation.sourceImageKey] else {
        guard masks.isEmpty else {
          throw PipelineEngineError.invalidInvocation("Interaction masks need their previous frame.")
        }
        return PipelineNodeResult(outputs: outputs)
      }
      guard case .image(let image) = value else {
        throw PipelineEngineError.invalidInvocation("Previous Frame needs an image input.")
      }
      guard masks.count <= 200, masks.allSatisfy({
        $0.mask.width == image.width && $0.mask.height == image.height
      }) else { throw PipelineEngineError.invalidInvocation("Previous masks do not match the frame.") }
      outputs["image"] = PipelineNodeValue(image, type: .image)
      return PipelineNodeResult(outputs: outputs)
    },
    PipelineNodeExecutor(kind: .sceneNavigationCrop) { node, inputs, _ in
      guard let plan = inputs["previousPlan"]?.value(as: String.self),
        let x = inputs["x"]?.value(as: Double.self),
        let y = inputs["y"]?.value(as: Double.self)
      else {
        throw PipelineEngineError.invalidInvocation(
          "Navigation Crop needs the previous plan and Trackpad X/Y.")
      }
      guard !plan.isEmpty else { return PipelineNodeResult() }
      guard let image = inputs["image"]?.value(as: PipelineImageInput.self) else {
        throw PipelineEngineError.invalidInvocation(
          "Navigation Crop needs the previous frame when a scene plan exists.")
      }
      let size = node.parameters["size"]?.integerValue ?? 1024
      let margin = node.parameters["margin"]?.numberValue ?? 1.5
      guard (256...2048).contains(size), margin.isFinite, (1...3).contains(margin) else {
        throw PipelineEngineError.invalidInvocation(
          "Navigation Crop size must be 256–2048 and margin 1–3.")
      }
      let crop = try PipelineNavigationCrop.make(
        image: image, plan: PipelineScenePlan.decode(plan), x: x, y: y,
        size: Int(size), margin: margin)
      return PipelineNodeResult(outputs: [
        "image": PipelineNodeValue(crop, type: .image)
      ])
    },
    PipelineNodeExecutor(kind: .sceneNavigate) { node, inputs, _ in
      guard let originalPrompt = inputs["originalPrompt"]?.value(as: String.self),
        let previousPlan = inputs["previousPlan"]?.value(as: String.self),
        let x = inputs["x"]?.value(as: Double.self),
        let y = inputs["y"]?.value(as: Double.self)
      else {
        throw PipelineEngineError.invalidInvocation(
          "Next View Brief \(node.id.rawValue) needs the original prompt, prior plan, and trackpad X/Y.")
      }
      let prompt = previousPlan.isEmpty ? originalPrompt
        : try PipelineScenePlan.decode(previousPlan).nextWriterPrompt(x: x, y: y)
      return PipelineNodeResult(outputs: [
        "prompt": PipelineNodeValue(prompt, type: .prompt)
      ])
    },
    PipelineNodeExecutor(kind: .scenePlanParse) { node, inputs, _ in
      guard let text = inputs["text"]?.value(as: String.self) else {
        throw PipelineEngineError.invalidInvocation(
          "Parse Scene Plan \(node.id.rawValue) needs scene-writer text.")
      }
      let plan = try PipelineScenePlan.decode(text)
      return PipelineNodeResult(outputs: [
        "prompt": PipelineNodeValue(plan.imagePrompt, type: .prompt),
        "scenePlan": PipelineNodeValue(try plan.encodedJSON(), type: .string),
      ])
    },
    PipelineNodeExecutor(kind: .imageOutput) { node, inputs, context in
      guard let input = inputs["image"] else {
        throw PipelineEngineError.planningFailed(
          "Image output \(node.id.rawValue) has no image input.")
      }
      var image: PipelineGeneratedImage
      if let generated = input.value(as: PipelineGeneratedImage.self) {
        image = generated
      } else if let raster = input.value(as: PipelineImageInput.self) {
        let pixels = raster.width * raster.height
        var planar = [Float](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
          for channel in 0..<3 {
            let alpha = raster.rgba[pixel * 4 + 3]
            planar[channel * pixels + pixel] = alpha > 0
              ? raster.rgba[pixel * 4 + channel] / alpha : 0
          }
        }
        image = PipelineGeneratedImage(
          width: raster.width, height: raster.height, planarRGB: planar,
          encoding: .sRGBZeroToOne,
          semanticPipelineSHA256: context.semanticSHA256,
          alpha: (0..<pixels).map { raster.rgba[$0 * 4 + 3] })
      } else {
        throw PipelineEngineError.planningFailed(
          "Image output \(node.id.rawValue) received an unsupported image value.")
      }
      if let planJSON = inputs["scenePlan"]?.value(as: String.self) {
        image.scenePlanJSON = try PipelineScenePlan.decode(planJSON).encodedJSON()
      }
      if let feedback = inputs["feedbackText"] {
        guard let text = feedback.value(as: String.self) else {
          throw PipelineEngineError.planningFailed(
            "Image output \(node.id.rawValue) received a non-text feedbackText value.")
        }
        image.feedbackText = text
      }
      if let state = inputs["nextState"] {
        guard let text = state.value(as: String.self) else {
          throw PipelineEngineError.invalidInvocation("Image Output needs JSON text for nextState.")
        }
        image.nextStateJSON = try PipelineStateJSON.canonicalObject(text)
      }
      if let supplied = inputs["interactionMasks"] {
        guard let masks = supplied.value(as: [PipelineLabeledMask].self) else {
          throw PipelineEngineError.invalidInvocation("Image Output needs labeled interaction masks.")
        }
        try image.setInteractionMasks(masks)
      }
      return PipelineNodeResult(terminalOutput: .image(image))
    },
    PipelineNodeExecutor(kind: .textOutput) { node, inputs, context in
      guard let text = inputs["text"]?.value(as: String.self) else {
        throw PipelineEngineError.planningFailed(
          "Text output \(node.id.rawValue) has no text input.")
      }
      return PipelineNodeResult(terminalOutput: .plainText(PipelinePlainText(
        text: text, semanticPipelineSHA256: context.semanticSHA256)))
    },
  ] + PipelineGeometryNodes.executors + PipelineStateNodes.executors
    + PipelineModelDesignNodes.executors
}

extension PipelineValue {
  var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }

  var integerValue: Int64? {
    if case .integer(let value) = self { value } else { nil }
  }

  var numberValue: Double? {
    switch self {
    case .number(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
  }
}
