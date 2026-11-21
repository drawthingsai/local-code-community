import CoreGraphics

/// How wide the chat column, which holds the transcript and the chat input, gets in a window with
/// room for it. Persisted by raw value.
enum ChatWidth: Int, CaseIterable {
  case normal = 0
  case wide = 1

  /// The column's widest. A transcript row is 64pt narrower.
  var maximumWidth: CGFloat {
    switch self {
    case .normal:
      return 960
    case .wide:
      // Room for 120-column code at the default text size, in a column that a full-screen window
      // on a 13-inch MacBook still reaches.
      return 1280
    }
  }
}
