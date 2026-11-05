import Localization

/// What the row under a settings item says, and how serious it is.
public struct SettingsWarning: Equatable {
  public enum Severity: Equatable {
    /// Yellow.
    case warning
    /// Red.
    case error
  }

  public var text: String
  public var severity: Severity

  public init(text: String, severity: Severity = .warning) {
    self.text = text
    self.severity = severity
  }

  public static var incompatible: SettingsWarning {
    SettingsWarning(text: LocalizedString.forKey("incompatible"))
  }
}
