import PixeltjePipelineDomain

enum PipelineStateNodes {
  static let executors: [PipelineNodeExecutor] = [
    PipelineNodeExecutor(kind: .stateInput, validate: { node in
      do {
        _ = try PipelineStateJSON.canonicalObject(node.parameters["initialState"]?.stringValue ?? "{}")
        return []
      } catch {
        return [.init(severity: .error, code: .invalidParameter,
          message: error.localizedDescription, nodeID: node.id)]
      }
    }) { node, _, context in
      let text = try context.invocation.string(for: PipelineInvocation.stateKey,
        default: node.parameters["initialState"]?.stringValue ?? "{}")
      return PipelineNodeResult(outputs: [
        "state": PipelineNodeValue(try PipelineStateJSON.canonicalObject(text), type: .string)
      ])
    },
    PipelineNodeExecutor(kind: .textJSONExtract) { node, inputs, _ in
      let json = inputs["json"]?.value(as: String.self) ?? node.parameters["json"]?.stringValue ?? ""
      let key = inputs["key"]?.value(as: String.self) ?? node.parameters["key"]?.stringValue ?? ""
      let selected = try PipelineStateJSON.read(json, key: key)
      var document = try PipelineStateJSON.canonicalObject(json)
      if let supplied = inputs["setValue"] {
        let replacement: PipelineValue
        if let value = supplied.value(as: String.self) { replacement = .string(value) }
        else if let value = supplied.value(as: Bool.self) { replacement = .boolean(value) }
        else if let value = supplied.value(as: Int.self) { replacement = .integer(Int64(value)) }
        else if let value = supplied.value(as: Int64.self) { replacement = .integer(value) }
        else if let value = supplied.value(as: Double.self) { replacement = .number(value) }
        else {
          throw PipelineEngineError.invalidInvocation("JSON Value can set text, Boolean or numeric values.")
        }
        document = try PipelineStateJSON.setting(document, key: key, to: replacement)
      }
      var outputs: [String: PipelineNodeValue] = [
        "value": PipelineNodeValue(try PipelineStateJSON.text(selected), type: .string),
        "json": PipelineNodeValue(document, type: .string),
      ]
      switch selected {
      case .integer(let value): outputs["number"] = PipelineNodeValue(Double(value), type: .number)
      case .number(let value): outputs["number"] = PipelineNodeValue(value, type: .number)
      case .boolean(let value): outputs["boolean"] = PipelineNodeValue(value, type: .boolean)
      case .array(let values):
        let strings = values.compactMap(\.stringValue)
        if strings.count == values.count { outputs["items"] = PipelineNodeValue(strings, type: .stringList) }
      default: break
      }
      return PipelineNodeResult(outputs: outputs)
    },
  ]
}
