import CoreFoundation
import Foundation

/// Plain, bounded JSON for host-owned state and reusable JSON operations.
/// This is distinct from PipelineValue's tagged document encoding.
public enum PipelineStateJSON {
  public static let maximumBytes = 65_536
  public static let maximumDepth = 32

  public static func canonicalObject(_ text: String) throws -> String {
    try encode(object(text))
  }

  public static func read(_ text: String, key: String) throws -> PipelineValue {
    var value = try object(text)
    for component in try components(key) {
      switch value {
      case .object(let fields):
        guard let next = fields[component] else { throw failure("Missing JSON key \(component).") }
        value = next
      case .array(let items):
        guard let index = Int(component), index >= 0, index < items.count,
          String(index) == component else { throw failure("Invalid JSON array index.") }
        value = items[index]
      default: throw failure("JSON path crosses a scalar value.")
      }
    }
    return value
  }

  public static func setting(_ text: String, key: String, to replacement: PipelineValue) throws -> String {
    let path = try components(key)
    func replacing(_ value: PipelineValue, _ path: ArraySlice<String>) throws -> PipelineValue {
      guard let first = path.first else { return replacement }
      switch value {
      case .object(var fields):
        guard let child = fields[first] else { throw failure("Missing JSON key \(first).") }
        fields[first] = try replacing(child, path.dropFirst())
        return .object(fields)
      case .array(var items):
        guard let index = Int(first), index >= 0, index < items.count,
          String(index) == first else { throw failure("Invalid JSON array index.") }
        items[index] = try replacing(items[index], path.dropFirst())
        return .array(items)
      default: throw failure("JSON path crosses a scalar value.")
      }
    }
    let updated = try replacing(object(text), path[...])
    guard case .object = updated else { throw failure("State must remain a JSON object.") }
    let encoded = try encode(updated)
    return try canonicalObject(encoded)
  }

  public static func text(_ value: PipelineValue) throws -> String {
    if case .string(let text) = value { return text }
    return try encode(value)
  }

  private static func object(_ text: String) throws -> PipelineValue {
    let data = Data(text.utf8)
    guard data.count <= maximumBytes else { throw failure("JSON exceeds 64 KiB.") }
    let value = try convert(JSONSerialization.jsonObject(with: data), depth: 0)
    guard case .object = value else { throw failure("State must be a JSON object.") }
    return value
  }

  private static func components(_ key: String) throws -> [String] {
    if key.isEmpty { return [] }
    if !key.hasPrefix("/") { return [key] }
    return try key.dropFirst().components(separatedBy: "/").map { part in
      var decoded = ""
      var iterator = part.makeIterator()
      while let character = iterator.next() {
        if character == "~" {
          guard let escape = iterator.next(), escape == "0" || escape == "1" else {
            throw failure("Invalid JSON Pointer escape.")
          }
          decoded.append(escape == "0" ? "~" : "/")
        } else { decoded.append(character) }
      }
      return decoded
    }
  }

  private static func convert(_ value: Any, depth: Int) throws -> PipelineValue {
    guard depth <= maximumDepth else { throw failure("JSON nesting exceeds 32 levels.") }
    switch value {
    case is NSNull: return .null
    case let text as String: return .string(text)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
      if let integer = Int64(number.stringValue) { return .integer(integer) }
      guard number.doubleValue.isFinite else { throw failure("JSON numbers must be finite.") }
      return .number(number.doubleValue)
    case let fields as [String: Any]:
      return .object(try fields.mapValues { try convert($0, depth: depth + 1) })
    case let items as [Any]:
      return .array(try items.map { try convert($0, depth: depth + 1) })
    default: throw failure("Unsupported JSON value.")
    }
  }

  private static func encode(_ value: PipelineValue) throws -> String {
    func plain(_ value: PipelineValue, depth: Int = 0) throws -> Any {
      guard depth <= maximumDepth else { throw failure("JSON nesting exceeds 32 levels.") }
      switch value {
      case .null: return NSNull()
      case .boolean(let value): return value
      case .integer(let value): return value
      case .number(let value):
        guard value.isFinite else { throw failure("JSON numbers must be finite.") }
        return value
      case .string(let value): return value
      case .array(let items): return try items.map { try plain($0, depth: depth + 1) }
      case .object(let fields): return try fields.mapValues { try plain($0, depth: depth + 1) }
      }
    }
    let data = try JSONSerialization.data(withJSONObject: plain(value), options: [.sortedKeys, .fragmentsAllowed])
    guard data.count <= maximumBytes else { throw failure("JSON exceeds 64 KiB.") }
    return String(decoding: data, as: UTF8.self)
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "PixeltjePipeline.JSON", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
