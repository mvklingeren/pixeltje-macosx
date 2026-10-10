import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@Test func launchSizeCreatesAOneOffCanvasRequest() throws {
  let separated = try PixeltjeMacLaunchOptions.parse(["--size", "1024x1024"])
  #expect(separated.urls.isEmpty)
  #expect(separated.newDocumentSize == CanvasRecipe(width: 1024, height: 1024))

  let joined = try PixeltjeMacLaunchOptions.parse(["--size=800X600"])
  #expect(joined.newDocumentSize == CanvasRecipe(width: 800, height: 600))
}

@Test func launchPathsContinueToOpenNormally() throws {
  let options = try PixeltjeMacLaunchOptions.parse(["photo.dng", "/tmp/shoot"])
  #expect(options.newDocumentSize == nil)
  #expect(options.urls.map(\.lastPathComponent) == ["photo.dng", "shoot"])
}

@Test func launchSizeRejectsMalformedOrConflictingInput() {
  #expect(throws: PixeltjeMacLaunchOptionError.self) {
    try PixeltjeMacLaunchOptions.parse(["--size", "1024"])
  }
  #expect(throws: PixeltjeMacLaunchOptionError.self) {
    try PixeltjeMacLaunchOptions.parse(["--size", "0x1024"])
  }
  #expect(throws: PixeltjeMacLaunchOptionError.self) {
    try PixeltjeMacLaunchOptions.parse(["--size", "1024x1024", "photo.dng"])
  }
  #expect(throws: PixeltjeMacLaunchOptionError.self) {
    try PixeltjeMacLaunchOptions.parse(["--unknown"])
  }
}
