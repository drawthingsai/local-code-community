import Foundation
import Localization
import RemoteAPI

enum RemoteStatusReport {
  enum Account {
    case notExposed
    case loading
    case openRouter(OpenRouterKeyStatus)
    case failed(String)
  }

  static func markdown(
    providerTitle: String?, agentStatus: RemoteAgentStatus?, account: Account
  ) -> String {
    var lines = ["**\(LocalizedString.forKey("remote_status_title"))**", ""]
    guard let providerTitle else {
      lines.append(LocalizedString.forKey("remote_status_provider_not_configured"))
      return lines.joined(separator: "\n")
    }
    lines.append(LocalizedString.format(key: "remote_status_provider", providerTitle))

    let count: (Int) -> String = {
      NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal)
    }
    if let agentStatus {
      lines.append(
        LocalizedString.format(
          key: "remote_status_context", count(agentStatus.estimatedContextTokens),
          count(agentStatus.effectiveContextWindowTokens), agentStatus.contextUsagePercentage))
      lines.append(
        LocalizedString.format(
          key: "remote_status_context_free", count(agentStatus.availableContextTokens)))
      if agentStatus.configuredContextWindowTokens != agentStatus.effectiveContextWindowTokens {
        lines.append(
          LocalizedString.format(
            key: "remote_status_configured_context",
            count(agentStatus.configuredContextWindowTokens)))
      }
      lines.append(
        LocalizedString.format(
          key: "remote_status_compaction_threshold", count(agentStatus.compactionThresholdTokens)))
      lines.append(
        LocalizedString.format(
          key: "remote_status_compaction_reserve", count(agentStatus.compactionReserveTokens)))
      lines.append(
        LocalizedString.format(
          key: "remote_status_output_reserve", count(agentStatus.reservedOutputTokens)))
      lines.append(
        LocalizedString.format(
          key: "remote_status_active_history", count(agentStatus.transcriptMessageCount)))
      if let currentRound = agentStatus.currentRound {
        lines.append(
          LocalizedString.format(
            key: "remote_status_current_turn", currentRound, agentStatus.maximumRounds))
      } else {
        lines.append(
          LocalizedString.format(key: "remote_status_turn_limit", agentStatus.maximumRounds))
      }
    } else {
      lines.append(LocalizedString.forKey("remote_status_select_project"))
    }

    lines.append("")
    switch account {
    case .notExposed:
      lines.append(LocalizedString.forKey("remote_status_account_quota_not_exposed"))
    case .loading:
      lines.append("**\(LocalizedString.forKey("remote_status_openrouter_account"))**")
      lines.append(LocalizedString.forKey("remote_status_checking_key_usage"))
    case .openRouter(let status):
      lines.append("**\(LocalizedString.forKey("remote_status_openrouter_account"))**")
      if let isFreeTier = status.isFreeTier {
        lines.append(
          LocalizedString.format(
            key: "remote_status_tier",
            LocalizedString.forKey(
              isFreeTier ? "remote_status_tier_free" : "remote_status_tier_funded")))
      }
      let currencyFormatter = NumberFormatter()
      currencyFormatter.numberStyle = .currency
      currencyFormatter.currencyCode = "USD"
      currencyFormatter.maximumFractionDigits = 4
      let currency: (Double) -> String = {
        currencyFormatter.string(from: NSNumber(value: $0))
          ?? String(format: "$%.4f", $0)
      }
      if let usage = status.usage {
        if let usageDaily = status.usageDaily {
          lines.append(
            LocalizedString.format(
              key: "remote_status_usage_with_today", currency(usage), currency(usageDaily)))
        } else {
          lines.append(LocalizedString.format(key: "remote_status_usage", currency(usage)))
        }
      }
      if let limit = status.limit {
        var limitAmount = currency(limit)
        if let limitReset = status.limitReset {
          limitAmount += " \(limitReset)"
        }
        if let limitRemaining = status.limitRemaining {
          lines.append(
            LocalizedString.format(
              key: "remote_status_key_limit_remaining", limitAmount, currency(limitRemaining)))
        } else {
          lines.append(LocalizedString.format(key: "remote_status_key_limit", limitAmount))
        }
      } else {
        lines.append(LocalizedString.forKey("remote_status_key_spending_limit_none"))
      }
      lines.append(LocalizedString.forKey("remote_status_free_model_requests_not_exposed"))
    case .failed(let message):
      lines.append("**\(LocalizedString.forKey("remote_status_openrouter_account"))**")
      lines.append(LocalizedString.format(key: "remote_status_unavailable", message))
    }
    return lines.joined(separator: "\n")
  }
}
