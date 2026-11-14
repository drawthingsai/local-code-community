import ProjectHistoryManager

/// A conversation as the model takes it: its tokens, and the images that fill the placeholders
/// among them. Two images of one size have the same tokens, so the tokens alone don't say which
/// conversation it is.
struct ResponsesPrompt: Equatable {
  var tokens = [Int32]()
  /// In the order of their place in `tokens`.
  var embedSpans = [EmbedSpan]()

  /// Whether this is `prompt` with more after it, which is what lets a KV cache of `prompt` carry
  /// on from where it ends.
  func continues(_ prompt: ResponsesPrompt) -> Bool {
    prompt.tokens.count < tokens.count && tokens.starts(with: prompt.tokens)
      && embedSpans.starts(with: prompt.embedSpans)
  }

  /// The first `length` tokens, with the images that are whole within them.
  func prefix(_ length: Int) -> ResponsesPrompt {
    ResponsesPrompt(
      tokens: Array(tokens.prefix(length)),
      embedSpans: embedSpans.filter { $0.start + $0.length <= Int64(length) })
  }
}
