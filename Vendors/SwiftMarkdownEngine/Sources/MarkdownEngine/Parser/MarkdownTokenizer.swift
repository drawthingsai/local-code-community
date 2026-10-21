//
//  MarkdownTokenizer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// The token namespace. Tokens are produced by `parseTokensViaAST`
// (`BlockScopedTokenizer`): block structure + block-level tokens come from
// `BlockParser` + `BlockLevelTokenizer` (hand scanners, no regex), inline
// tokens from the AST (`InlineParser` → `InlineASTAdapter`). This file keeps
// only the code-block language helper.
import Foundation

// MARK: - Tokenizer
enum MarkdownTokenizer {

  // MARK: - Code Block Helpers

  static func extractLanguage(from token: MarkdownToken, in text: String) -> String? {
    guard token.kind == .codeBlock,
      let openingMarker = token.markerRanges.first
    else { return nil }

    let nsText = text as NSString
    let markerEnd = NSMaxRange(openingMarker)
    guard markerEnd <= nsText.length,
      let openingFence = BacktickFence.match(in: nsText, lineRange: openingMarker)
    else { return nil }
    let languageStart = openingFence.markerLocation + 3
    let langRange = NSRange(location: languageStart, length: markerEnd - languageStart)

    let langString = nsText.substring(with: langRange).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return langString.isEmpty ? nil : langString
  }
}
