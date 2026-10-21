import Foundation
import RemoteAPI

/// The welcome thread is a built-in workspace item, never a model conversation.
struct OnboardingState {
  static let threadIdentifier: Int64 = -2

  /// The local models offered in onboarding: both DeepSeek variants and the one Qwen variant
  /// that suits this much memory. The first is preselected.
  static func offeredLocalModels(physicalMemory: UInt64) -> [String] {
    let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    let deepSeek41 = "deepseek_4.1_flash_1017_i2x.ckpt"
    let deepSeek4 = "deepseek_4_flash_0731_i2x.ckpt"
    // Leave room beyond the weights for Qwen's roughly 7 GiB context cache and the OS. The
    // 8-bit variant is never offered here; it is only in the model list.
    let qwen =
      physicalMemory >= 32 * gibibyte ? "qwen_3.8_27b_i4x.ckpt" : "qwen_3.8_27b_i2x.ckpt"
    if physicalMemory >= 96 * gibibyte {
      return [deepSeek41, deepSeek4, qwen]
    } else if physicalMemory >= 64 * gibibyte {
      return [deepSeek4, deepSeek41, qwen]
    }
    return [qwen, deepSeek41, deepSeek4]
  }

  enum Step: Int, CaseIterable {
    case welcome, model, account, finished
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

  var steps: [Step] {
    Step.allCases.filter { $0 != .account || !isAccountSignedIn }
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
    case .account, .finished:
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
