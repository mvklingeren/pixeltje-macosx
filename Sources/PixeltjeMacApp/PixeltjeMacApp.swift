import AppKit
import Foundation
import PixeltjeMacKit

@main
struct PixeltjeMacApplication {
  @MainActor
  static func main() {
    let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
      ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
    if let iconURL, let icon = NSImage(contentsOf: iconURL) {
      NSApplication.shared.applicationIconImage = icon
    }

    do {
      let options = try PixeltjeMacLaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
      runPixeltjeMacApplication(options: options)
    } catch {
      let message = "error: \(error.localizedDescription)\nusage: PixeltjeMacApp [--size WIDTHxHEIGHT | FILE_OR_FOLDER ...]\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(EXIT_FAILURE)
    }
  }
}
