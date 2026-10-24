/// Action keys a WASD Pad reports besides its movement axes. Each held key
/// sets one bit of the pad's `keys` output, which a GPU Program receives in
/// `movement.w`. Bits stay below 2^24 so the mask survives a 32-bit float.
///
/// | Key | Bit | Value |
/// | --- | --- | ----- |
/// | Q   | 0   | 1     |
/// | E   | 1   | 2     |
/// | R   | 2   | 4     |
/// | C   | 3   | 8     |
/// | V   | 4   | 16    |
/// | X   | 5   | 32    |
/// | Z   | 6   | 64    |
/// | 1–9 | 7–15 | 128 << (digit − 1) |
/// | H   | 16  | 65536 |
/// | K   | 17  | 131072 |
///
/// F, J, Space, Return and Escape keep their preview meanings and are not
/// reported.
public enum PipelineDirectionPadKeys {
  public static let letters = ["q", "e", "r", "c", "v", "x", "z", "h", "k"]
  public static let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
  public static let allMask = (1 << 18) - 1

  /// The bit for one typed key, or nil when the pad does not report it.
  public static func bit(for key: String) -> Int? {
    let key = key.lowercased()
    if key == "h" { return 1 << 16 }
    if key == "k" { return 1 << 17 }
    if let index = letters.firstIndex(of: key) { return 1 << index }
    if let index = digits.firstIndex(of: key) { return 1 << (7 + index) }
    return nil
  }

  public static func isValidMask(_ value: Double) -> Bool {
    value.isFinite && value.rounded(.towardZero) == value
      && (0...Double(allMask)).contains(value)
  }
}
