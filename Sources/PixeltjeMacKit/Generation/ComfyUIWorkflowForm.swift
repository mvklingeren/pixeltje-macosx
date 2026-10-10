import CoreFoundation
import Foundation
import PixeltjeMacDomain

enum ComfyUIParameterControl: Equatable, Sendable {
  case integer(isUnsigned: Bool)
  case decimal
  case boolean
  case text(multiline: Bool)
  case choice([ComfyUIParameterValue])
  case unsupported(String)
}

struct ComfyUIParameterDefinition: Identifiable, Equatable, Sendable {
  var address: ComfyUIParameterAddress
  var label: String
  var control: ComfyUIParameterControl
  var templateValue: ComfyUIParameterValue?
  var minimum: ComfyUIParameterValue?
  var maximum: ComfyUIParameterValue?
  var step: ComfyUIParameterValue?
  var tooltip: String?
  var isAdvanced: Bool
  var isConnected: Bool

  var id: ComfyUIParameterAddress { address }

  func normalized(_ proposed: ComfyUIParameterValue) -> ComfyUIParameterValue? {
    switch control {
    case .integer(let isUnsigned):
      if isUnsigned {
        guard var value = proposed.unsignedIntegerValue else { return nil }
        if let minimum = minimum?.unsignedIntegerValue { value = max(value, minimum) }
        if let maximum = maximum?.unsignedIntegerValue { value = min(value, maximum) }
        return .unsignedInteger(value)
      }
      guard var value = proposed.signedIntegerValue else { return nil }
      if let minimum = minimum?.signedIntegerValue { value = max(value, minimum) }
      if let maximum = maximum?.signedIntegerValue { value = min(value, maximum) }
      return .signedInteger(value)
    case .decimal:
      guard var value = proposed.doubleValue, value.isFinite else { return nil }
      if let minimum = minimum?.doubleValue { value = max(value, minimum) }
      if let maximum = maximum?.doubleValue { value = min(value, maximum) }
      return .decimal(value)
    case .boolean:
      guard case .boolean = proposed else { return nil }
      return proposed
    case .text:
      guard case .string = proposed else { return nil }
      return proposed
    case .choice(let options):
      return options.contains(proposed) ? proposed : nil
    case .unsupported:
      return nil
    }
  }
}

struct ComfyUIWorkflowNodeDefinition: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var classType: String
  var order: Int
  var parameters: [ComfyUIParameterDefinition]
}

struct ComfyUIWorkflowForm: Equatable, Sendable {
  var templateID: String
  var templateRevision: String
  var nodes: [ComfyUIWorkflowNodeDefinition]
  var templateValues: [ComfyUIParameterAddress: ComfyUIParameterValue]

  var parameters: [ComfyUIParameterDefinition] {
    nodes.flatMap(\.parameters)
  }

  /// Nodes that contribute controls or driven scalar values to the Develop panel.
  /// Connection-only graph plumbing remains in `nodes` for authored ordering, but
  /// does not need an empty settings card.
  var settingsNodes: [ComfyUIWorkflowNodeDefinition] {
    nodes.filter { !$0.parameters.isEmpty }
  }

  func parameter(at address: ComfyUIParameterAddress) -> ComfyUIParameterDefinition? {
    for node in nodes {
      if let parameter = node.parameters.first(where: { $0.address == address }) {
        return parameter
      }
    }
    return nil
  }
}

enum ComfyUIWorkflowFormState: Equatable, Sendable {
  case unavailable
  case loading
  case ready(ComfyUIWorkflowForm)
  case failed(String)

  var form: ComfyUIWorkflowForm? {
    if case .ready(let form) = self { return form }
    return nil
  }
}

extension ComfyUIParameterValue {
  var displayValue: String {
    switch self {
    case .string(let value): value
    case .signedInteger(let value): String(value)
    case .unsignedInteger(let value): String(value)
    case .decimal(let value): value.formatted(.number.precision(.fractionLength(0...8)))
    case .boolean(let value): value ? "On" : "Off"
    }
  }

  var signedIntegerValue: Int64? {
    switch self {
    case .signedInteger(let value): value
    case .unsignedInteger(let value) where value <= UInt64(Int64.max): Int64(value)
    default: nil
    }
  }

  var unsignedIntegerValue: UInt64? {
    switch self {
    case .unsignedInteger(let value): value
    case .signedInteger(let value) where value >= 0: UInt64(value)
    default: nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .signedInteger(let value): Double(value)
    case .unsignedInteger(let value): Double(value)
    case .decimal(let value): value
    default: nil
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var booleanValue: Bool? {
    if case .boolean(let value) = self { return value }
    return nil
  }

  var jsonObject: Any {
    switch self {
    case .string(let value): value
    case .signedInteger(let value): NSNumber(value: value)
    case .unsignedInteger(let value): NSNumber(value: value)
    case .decimal(let value): NSNumber(value: value)
    case .boolean(let value): NSNumber(value: value)
    }
  }

  static func workflowScalar(_ object: Any, preferUnsigned: Bool = false)
    -> ComfyUIParameterValue?
  {
    if let string = object as? String { return .string(string) }
    guard let number = object as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .boolean(number.boolValue)
    }

    let encoding = String(cString: number.objCType)
    if encoding == "f" || encoding == "d" {
      return .decimal(number.doubleValue)
    }
    if preferUnsigned || encoding.first == "Q" || encoding.first == "L" {
      return .unsignedInteger(number.uint64Value)
    }
    return .signedInteger(number.int64Value)
  }
}
