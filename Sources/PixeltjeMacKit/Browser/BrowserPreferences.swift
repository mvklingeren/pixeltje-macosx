import Foundation

enum BrowserPreferences {
  static let scansSubfoldersKey = "BrowserScansSubfolders"
  static let marginKey = "BrowserThumbnailMargin"
  static let thumbnailSizeKey = "BrowserThumbnailSize"
  static let preloadCountKey = "BrowserThumbnailPreloadCount"
  static let defaultPreloadCount = 24

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      scansSubfoldersKey: true,
      marginKey: 10.0,
      thumbnailSizeKey: 200.0,
      preloadCountKey: defaultPreloadCount,
    ])
  }

  static var scansSubfolders: Bool {
    UserDefaults.standard.bool(forKey: scansSubfoldersKey)
  }

  static var margin: Double {
    min(max(UserDefaults.standard.double(forKey: marginKey), 0), 40)
  }

  static var thumbnailSize: Double {
    min(max(UserDefaults.standard.double(forKey: thumbnailSizeKey), 90), 420)
  }

  static var preloadCount: Int {
    min(max(UserDefaults.standard.integer(forKey: preloadCountKey), 0), 60)
  }
}
