import Foundation
import RemoteAPI

/// The welcome thread is a built-in workspace item, never a model conversation.
struct OnboardingState {
  static let threadIdentifier: Int64 = -2

  /// The local models offered in onboarding: both DeepSeek variants and the one Inkling 2 Mini
  /// variant that suits this much memory, then Inkling 2 Small. The first is preselected:
  /// Inkling 2 Mini below 64 GiB, DeepSeek from there. Inkling 2 Small never is.
  static func offeredLocalModels(physicalMemory: UInt64) -> [String] {
    let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    let deepSeek41 = "deepseek_4.1_flash_1017_i2x.ckpt"
    let deepSeek4 = "deepseek_4_flash_0731_i2x.ckpt"
    let inklingMini =
      physicalMemory >= 32 * gibibyte ? "inkling_2_mini_i4x.ckpt" : "inkling_2_mini_i3x.ckpt"
    let inklingSmall = "inkling_2_small_i2x.ckpt"
    if physicalMemory >= 96 * gibibyte {
      return [deepSeek41, deepSeek4, inklingMini, inklingSmall]
    } else if physicalMemory >= 64 * gibibyte {
      return [deepSeek4, deepSeek41, inklingMini, inklingSmall]
    }
    return [inklingMini, deepSeek41, deepSeek4, inklingSmall]
  }

  enum Step: Int, CaseIterable {
    case welcome, model, account, readingStyle, finished
  }

  /// A message text size offered on the reading style page. The raw value is the message zoom
  /// in percent.
  enum TextSize: Int, CaseIterable {
    case smaller = 90
    case normal = 100
    case bigger = 120
  }

  enum Selection: Hashable {
    case local
    case remote(RemoteProvider)
  }

  /// A starter project offered on the last page, laid out in this order. The raw value is the
  /// localization key of its title, which also names its folder, and of its detail with a
  /// `_detail` suffix.
  enum ProjectIdea: String, CaseIterable {
    case fileOrganizer = "file_organizer"
    case houseChores = "house_chores"
    case dailyBrief = "daily_brief"
    case taxProofread = "tax_proofread"
    case graphicNovelist = "graphic_novelist"
    case explainerVideos = "explainer_videos"
    case officeWork = "office_work"

    /// The English title, which names this idea's folder in the community templates.
    var templateName: String {
      Bundle.main.path(forResource: "en", ofType: "lproj").flatMap { Bundle(path: $0) }?
        .localizedString(forKey: rawValue, value: nil, table: nil) ?? rawValue
    }
  }

  var step: Step = .welcome
  var selection = Selection.local
  var welcomeCompleted = false
  var isAccountSignedIn = false
  var isProviderConnected = false
  var isModelSelected = false
  var projectIdeas: Set<ProjectIdea> = [
    .fileOrganizer, .houseChores, .dailyBrief, .taxProofread,
  ]
  var isBotModeEnabled = false
  /// The phone layout has neither the message zoom nor the chat width, so it has no reading
  /// style page.
  var offersReadingStyle = true

  var steps: [Step] {
    Step.allCases.filter {
      ($0 != .account || !isAccountSignedIn) && ($0 != .readingStyle || offersReadingStyle)
    }
  }

  var canSkipAccount: Bool {
    selection == .local || (selection != .remote(.localCode) && isProviderConnected)
  }

  var canContinue: Bool {
    switch step {
    case .welcome: return welcomeCompleted
    case .model:
      return selection == .local || (selection == .remote(.localCode) && !isAccountSignedIn)
        || (isProviderConnected && isModelSelected)
    case .account, .readingStyle, .finished:
      if selection == .local { return true }
      if selection == .remote(.localCode) {
        return isAccountSignedIn && isProviderConnected && isModelSelected
      }
      return isProviderConnected && isModelSelected
    }
  }

  mutating func advance() {
    guard canContinue, let next = steps.first(where: { $0.rawValue > step.rawValue }) else {
      return
    }
    step = next
  }

  mutating func goBack() {
    guard let previous = steps.last(where: { $0.rawValue < step.rawValue }) else { return }
    step = previous
  }
}
