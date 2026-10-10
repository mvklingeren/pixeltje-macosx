import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let reroute = PipelineNodeKind(rawValue: "utility.reroute")
  public static let textLength = PipelineNodeKind(rawValue: "text.length")
  public static let textContains = PipelineNodeKind(rawValue: "text.contains")
  public static let textSubstring = PipelineNodeKind(rawValue: "text.substring")
  public static let textCompare = PipelineNodeKind(rawValue: "text.compare")
  public static let textTrim = PipelineNodeKind(rawValue: "text.trim")
  public static let textChangeCase = PipelineNodeKind(rawValue: "text.changeCase")
  public static let textRegexMatch = PipelineNodeKind(rawValue: "text.regexMatch")
  public static let textRegexExtract = PipelineNodeKind(rawValue: "text.regexExtract")
}

extension PipelineNodeRegistry {
  /// Graph-readability and string utilities. Every string operand is also an
  /// optional input so a connected value overrides the saved fallback.
  static var utilityDescriptors: [PipelineNodeDescriptor] {
    [
      PipelineNodeDescriptor(
        kind: .reroute,
        displayName: "Reroute",
        category: "Utilities",
        inputs: [.init(name: "value", type: .any, typeVariable: "value")],
        outputs: [.init(name: "value", type: .any, typeVariable: "value")]),
      PipelineNodeDescriptor(
        kind: .textLength,
        displayName: "Text Length",
        category: "Text",
        inputs: [.init(name: "string", type: .string, isRequired: false)],
        outputs: [.init(name: "length", type: .integer)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string(""))
        ]),
      PipelineNodeDescriptor(
        kind: .textContains,
        displayName: "Text Contains",
        category: "Text",
        inputs: [
          .init(name: "string", type: .string, isRequired: false),
          .init(name: "substring", type: .string, isRequired: false),
          .init(name: "caseSensitive", type: .boolean, isRequired: false),
        ],
        outputs: [.init(name: "result", type: .boolean)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "substring", valueType: .string, defaultValue: .string("")),
          .init(name: "caseSensitive", valueType: .boolean, defaultValue: .boolean(true)),
        ]),
      PipelineNodeDescriptor(
        kind: .textSubstring,
        displayName: "Substring",
        category: "Text",
        inputs: [
          .init(name: "string", type: .string, isRequired: false),
          .init(name: "start", type: .integer, isRequired: false),
          .init(name: "end", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "start", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "end", valueType: .integer, defaultValue: .integer(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .textCompare,
        displayName: "Compare Text",
        category: "Text",
        inputs: [
          .init(name: "stringA", type: .string, isRequired: false),
          .init(name: "stringB", type: .string, isRequired: false),
          .init(name: "caseSensitive", type: .boolean, isRequired: false),
        ],
        outputs: [.init(name: "result", type: .boolean)],
        parameters: [
          .init(name: "stringA", valueType: .string, defaultValue: .string("")),
          .init(name: "stringB", valueType: .string, defaultValue: .string("")),
          .init(name: "mode", valueType: .string, defaultValue: .string("Equal")),
          .init(name: "caseSensitive", valueType: .boolean, defaultValue: .boolean(true)),
        ]),
      PipelineNodeDescriptor(
        kind: .textTrim,
        displayName: "Trim Text",
        category: "Text",
        inputs: [.init(name: "string", type: .string, isRequired: false)],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "mode", valueType: .string, defaultValue: .string("Both")),
        ]),
      PipelineNodeDescriptor(
        kind: .textChangeCase,
        displayName: "Change Text Case",
        category: "Text",
        inputs: [.init(name: "string", type: .string, isRequired: false)],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "mode", valueType: .string, defaultValue: .string("UPPERCASE")),
        ]),
      PipelineNodeDescriptor(
        kind: .textRegexMatch,
        displayName: "Match Text (Regex)",
        category: "Text",
        inputs: [
          .init(name: "string", type: .string, isRequired: false),
          .init(name: "pattern", type: .string, isRequired: false),
          .init(name: "caseInsensitive", type: .boolean, isRequired: false),
          .init(name: "multiline", type: .boolean, isRequired: false),
          .init(name: "dotAll", type: .boolean, isRequired: false),
        ],
        outputs: [.init(name: "result", type: .boolean)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "pattern", valueType: .string, defaultValue: .string("")),
          .init(name: "caseInsensitive", valueType: .boolean, defaultValue: .boolean(true)),
          .init(name: "multiline", valueType: .boolean, defaultValue: .boolean(false)),
          .init(name: "dotAll", valueType: .boolean, defaultValue: .boolean(false)),
        ]),
      PipelineNodeDescriptor(
        kind: .textRegexExtract,
        displayName: "Extract Text (Regex)",
        category: "Text",
        inputs: [
          .init(name: "string", type: .string, isRequired: false),
          .init(name: "pattern", type: .string, isRequired: false),
          .init(name: "caseInsensitive", type: .boolean, isRequired: false),
          .init(name: "multiline", type: .boolean, isRequired: false),
          .init(name: "dotAll", type: .boolean, isRequired: false),
          .init(name: "groupIndex", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "pattern", valueType: .string, defaultValue: .string("")),
          .init(name: "mode", valueType: .string, defaultValue: .string("First Match")),
          .init(name: "caseInsensitive", valueType: .boolean, defaultValue: .boolean(true)),
          .init(name: "multiline", valueType: .boolean, defaultValue: .boolean(false)),
          .init(name: "dotAll", valueType: .boolean, defaultValue: .boolean(false)),
          .init(name: "groupIndex", valueType: .integer, defaultValue: .integer(1)),
        ]),
    ]
  }
}
