//
//  BlockScopedTokenizer.swift
//  MarkdownEngine
//
//  The live tokenization pipeline. For each block from `BlockParser`:
//  block-level tokens (heading, blockquote, table, block LaTeX, code) come from
//  `BlockLevelTokenizer` (hand scanners, no regex), while ALL inline tokens come
//  from the AST (`InlineParser` → `InlineASTAdapter`). Results are offset back
//  into document coordinates. Fenced-code blocks emit only their code-block
//  token (no inline markup inside).
//

import Foundation

extension MarkdownTokenizer {

  private struct CachedBlockParse {
    let tokens: [MarkdownToken]
    let autoLinkRanges: [NSRange]
  }

  /// Per-block memo (substring → block-relative parse): only the edited block re-parses, O(change). FIFO-capped, locked.
  private static let blockParseLock = NSLock()
  private static var blockParseCache: [String: CachedBlockParse] = [:]
  private static var blockParseOrder: [String] = []
  private static let blockParseCacheCap = 4096

  // Document-level token memo: re-tokenize only the touched blocks; the rest shift by the delta.
  private static let tokensLock = NSLock()
  private static var cachedTokenChars: [unichar]?
  private static var cachedTokens: [MarkdownToken]?
  /// Registry fingerprint the memo was computed under — a different set of
  /// registered extensions yields different tokens for identical text.
  private static var cachedTokenFingerprint: String = ""

  /// The live tokenizer: block-level tokens + inline AST tokens; fenced code emits only its code-block token.
  static func parseTokensViaAST(in text: String, registry: ExtensionRegistry = .empty)
    -> [MarkdownToken]
  {
    let t0 = DispatchTime.now().uptimeNanoseconds
    defer {
      PerfTrace.note {
        "🗜️ tokenizer.static \(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))ms"
      }
    }
    let ns = text as NSString
    let newLen = ns.length
    var newChars = [unichar](repeating: 0, count: newLen)
    if newLen > 0 { ns.getCharacters(&newChars, range: NSRange(location: 0, length: newLen)) }

    let blocks = BlockParser.parse(text, utf16Chars: newChars, registry: registry)

    tokensLock.lock()
    let prevChars = cachedTokenFingerprint == registry.fingerprint ? cachedTokenChars : nil
    let prevTokens = cachedTokenFingerprint == registry.fingerprint ? cachedTokens : nil
    tokensLock.unlock()

    let result: [MarkdownToken]
    if let prevChars, let prevTokens {
      if let diff = BlockParser.scanDiff(old: prevChars, new: newChars) {
        result =
          incrementalTokens(
            oldChars: prevChars, prevTokens: prevTokens, newChars: newChars, blocks: blocks, ns: ns,
            diff: diff, registry: registry)?.tokens
          ?? fullTokens(blocks: blocks, ns: ns, registry: registry)
      } else {
        result = prevTokens  // identical text
      }
    } else {
      result = fullTokens(blocks: blocks, ns: ns, registry: registry)
    }

    tokensLock.lock()
    cachedTokenChars = newChars
    cachedTokens = result
    cachedTokenFingerprint = registry.fingerprint
    tokensLock.unlock()
    return result
  }

  /// Adopt an externally computed parse (DocumentParseState publishes its
  /// per-keystroke result) so static-path callers hit instead of re-splicing
  /// against a one-keystroke-stale cache.
  static func seedCache(chars: [unichar], tokens: [MarkdownToken], fingerprint: String = "") {
    tokensLock.lock()
    cachedTokenChars = chars
    cachedTokens = tokens
    cachedTokenFingerprint = fingerprint
    tokensLock.unlock()
  }

  /// Display-content ranges eligible for automatic URL detection. These are projected from the
  /// same AST as styling tokens, so Markdown markers and explicit link destinations never enter
  /// the detector's input range while code content remains eligible.
  static func autoLinkRangesViaAST(
    in text: String,
    scopedRanges: [NSRange]? = nil,
    precomputedBlocks: [Block]? = nil,
    registry: ExtensionRegistry = .empty
  ) -> [NSRange] {
    let ns = text as NSString
    let blocks = precomputedBlocks ?? BlockParser.parse(text, registry: registry)
    var result: [NSRange] = []
    for block in blocks {
      if let scopedRanges,
        !scopedRanges.contains(where: { NSIntersectionRange($0, block.range).length > 0 })
      {
        continue
      }
      let parsed = cachedBlockParse(
        kind: block.kind, sub: ns.substring(with: block.range), registry: registry)
      result.append(
        contentsOf: parsed.autoLinkRanges.map {
          NSRange(location: $0.location + block.range.location, length: $0.length)
        })
    }
    return result
  }

  static func fullTokens(blocks: [Block], ns: NSString, registry: ExtensionRegistry = .empty)
    -> [MarkdownToken]
  {
    var result: [MarkdownToken] = []
    for block in blocks {
      let delta = block.range.location
      let relTokens = cachedBlockTokens(
        kind: block.kind, sub: ns.substring(with: block.range), registry: registry)
      result.append(contentsOf: relTokens.map { $0.shifted(by: delta) })
    }
    return result
  }

  /// Reuse prefix/suffix tokens (suffix shifted) and re-tokenize only touched blocks,
  /// against a precomputed change region; nil to fall back to full.
  static func incrementalTokens(
    oldChars o: [unichar], prevTokens: [MarkdownToken], newChars n: [unichar], blocks: [Block],
    ns: NSString, diff: BufferDiff, registry: ExtensionRegistry = .empty
  ) -> (tokens: [MarkdownToken], retok: Int)? {
    let oldLen = o.count
    let newLen = n.count
    guard oldLen > 0, newLen > 0, !blocks.isEmpty else { return nil }

    let delta = diff.delta
    let changeStart = diff.changeStart
    let changeEndNew = diff.changeEndNew
    guard changeStart >= 0, diff.changeEndOld <= oldLen, changeEndNew <= newLen,
      changeStart <= diff.changeEndOld, changeStart <= changeEndNew
    else { return nil }

    // A fence/block-LaTeX/extension delimiter can pair with a distant partner and ripple far → full tokenization.
    let fences = registry.blockEntries.map(\.fenceChars)
    if BlockParser.hasBlockDelimiter(o, changeStart, diff.changeEndOld, fences: fences)
      || BlockParser.hasBlockDelimiter(n, changeStart, changeEndNew, fences: fences)
    {
      return nil
    }

    // New blocks touching the changed char range [changeStart, changeEndNew].
    // Blocks tile in order → the touching set is one contiguous run;
    // binary search replaces the O(#blocks) full scan per keystroke.
    var lo = 0
    var hi = blocks.count - 1
    while lo < hi {  // first block ending >= changeStart
      let m = (lo + hi) / 2
      if NSMaxRange(blocks[m].range) >= changeStart { hi = m } else { lo = m + 1 }
    }
    var first = lo
    lo = 0
    hi = blocks.count - 1
    while lo < hi {  // last block starting <= changeEndNew
      let m = (lo + hi + 1) / 2
      if blocks[m].range.location <= changeEndNew { lo = m } else { hi = m - 1 }
    }
    let last = lo
    // Validate the run actually touches (mirrors the old filter exactly).
    if first > last || blocks[first].range.location > changeEndNew
      || NSMaxRange(blocks[last].range) < changeStart
    {
      return delta == 0 ? (prevTokens, 0) : nil
    }
    lo = first
    hi = last

    // Widen the window until no previous token straddles either cut (a block's extent can change in place).
    var expanded = true
    while expanded {
      expanded = false
      for t in prevTokens {
        let cutStart = blocks[lo].range.location
        if t.range.location < cutStart, NSMaxRange(t.range) > cutStart {
          while lo > 0, blocks[lo].range.location > t.range.location {
            lo -= 1
            expanded = true
          }
        }
        let cutEndOld = NSMaxRange(blocks[hi].range) - delta
        if t.range.location < cutEndOld, NSMaxRange(t.range) > cutEndOld {
          while hi < blocks.count - 1, NSMaxRange(blocks[hi].range) - delta < NSMaxRange(t.range) {
            hi += 1
            expanded = true
          }
        }
      }
    }

    let regionStart = blocks[lo].range.location
    let regionEndOld = NSMaxRange(blocks[hi].range) - delta

    var result: [MarkdownToken] = []
    for t in prevTokens where NSMaxRange(t.range) <= regionStart { result.append(t) }  // prefix, unchanged
    for i in lo...hi {  // changed window, retokenized
      let off = blocks[i].range.location
      let rel = cachedBlockTokens(
        kind: blocks[i].kind, sub: ns.substring(with: blocks[i].range), registry: registry)
      result.append(contentsOf: rel.map { $0.shifted(by: off) })
    }
    for t in prevTokens where t.range.location >= regionEndOld {
      result.append(t.shifted(by: delta))
    }  // suffix, shifted
    return (result, hi - lo + 1)
  }

  /// Cached block-relative tokens for `sub` (computed on miss); a pure memo over
  /// the token logic. The key carries the registry fingerprint — the same text
  /// tokenizes differently under a different extension set.
  static func cachedBlockTokens(kind: BlockKind, sub: String, registry: ExtensionRegistry = .empty)
    -> [MarkdownToken]
  {
    cachedBlockParse(kind: kind, sub: sub, registry: registry).tokens
  }

  private static func cachedBlockParse(
    kind: BlockKind, sub: String, registry: ExtensionRegistry = .empty
  ) -> CachedBlockParse {
    let key = registry.fingerprint.isEmpty ? sub : registry.fingerprint + "\u{1F}" + sub
    blockParseLock.lock()
    if let cached = blockParseCache[key] {
      blockParseLock.unlock()
      return cached
    }
    blockParseLock.unlock()

    let blockLevel = BlockLevelTokenizer.tokens(for: kind, in: sub as NSString, registry: registry)
    // Fenced code is opaque — no inline markup inside it. Extension blocks
    // parse inlines over their CONTENT only (the fence lines are syntax —
    // a `$x$` in the info string must not become a latex token).
    let inlineNodes: [InlineNode]
    if kind == .fencedCode {
      inlineNodes = []
    } else if case .ext = kind, let block = blockLevel.first {
      let ns = sub as NSString
      let content = block.contentRange
      inlineNodes =
        content.length > 0
        ? InlineParser.parse(ns, range: content, registry: registry)
        : []
    } else {
      inlineNodes = InlineParser.parse(sub, registry: registry)
    }
    let tokens = blockLevel + InlineASTAdapter.tokens(from: inlineNodes)
    let autoLinkRanges: [NSRange]
    switch kind {
    case .fencedCode:
      autoLinkRanges = blockLevel.first.map { [$0.contentRange] } ?? []
    case .blockLatex, .table, .thematicBreak, .blank:
      autoLinkRanges = []
    case .paragraph, .heading, .blockquote, .list, .ext:
      autoLinkRanges = InlineASTAdapter.autoLinkRanges(from: inlineNodes)
    }
    let computed = CachedBlockParse(tokens: tokens, autoLinkRanges: autoLinkRanges)

    blockParseLock.lock()
    if blockParseCache[key] == nil {
      blockParseCache[key] = computed
      blockParseOrder.append(key)
      if blockParseOrder.count > blockParseCacheCap {
        blockParseCache[blockParseOrder.removeFirst()] = nil
      }
    }
    blockParseLock.unlock()
    return computed
  }
}

extension MarkdownToken {
  /// Returns a copy with every range moved forward by `delta` UTF-16 units.
  fileprivate func shifted(by delta: Int) -> MarkdownToken {
    func move(_ r: NSRange) -> NSRange {
      NSRange(location: r.location + delta, length: r.length)
    }
    return MarkdownToken(
      kind: kind,
      range: move(range),
      contentRange: move(contentRange),
      markerRanges: markerRanges.map(move)
    )
  }
}
