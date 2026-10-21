//
//  TextReplacementDiff.swift
//  MarkdownEngine
//
//  Resolves two complete string snapshots into one containing replacement.
//  TextKit ranges are UTF-16, so the result is expressed as NSRanges while
//  widening boundaries when necessary to avoid splitting composed characters.
//

import Foundation

struct TextReplacementDiff {
  let oldRange: NSRange
  let newRange: NSRange

  var delta: Int { newRange.length - oldRange.length }

  init?(old: String, new: String) {
    let oldText = old as NSString
    let newText = new as NSString
    let oldLength = oldText.length
    let newLength = newText.length
    let sharedLength = min(oldLength, newLength)

    var prefixLength = 0
    while prefixLength < sharedLength,
      oldText.character(at: prefixLength) == newText.character(at: prefixLength)
    {
      prefixLength += 1
    }
    guard prefixLength != oldLength || oldLength != newLength else { return nil }

    var suffixLength = 0
    let maximumSuffixLength = sharedLength - prefixLength
    while suffixLength < maximumSuffixLength,
      oldText.character(at: oldLength - suffixLength - 1)
        == newText.character(at: newLength - suffixLength - 1)
    {
      suffixLength += 1
    }

    // UTF-16 comparison can stop inside a surrogate pair or a composed
    // character. The edit descriptor may be wider than the minimal diff, so
    // move its boundaries outward and keep TextKit mutations well-formed.
    if prefixLength > 0, prefixLength < oldLength {
      let range = oldText.rangeOfComposedCharacterSequence(at: prefixLength)
      if range.location < prefixLength { prefixLength = range.location }
    }
    if prefixLength > 0, prefixLength < newLength {
      let range = newText.rangeOfComposedCharacterSequence(at: prefixLength)
      if range.location < prefixLength { prefixLength = range.location }
    }

    var oldEnd = oldLength - suffixLength
    var newEnd = newLength - suffixLength
    if oldEnd > 0, oldEnd < oldLength {
      let range = oldText.rangeOfComposedCharacterSequence(at: oldEnd)
      if range.location < oldEnd { oldEnd = NSMaxRange(range) }
    }
    if newEnd > 0, newEnd < newLength {
      let range = newText.rangeOfComposedCharacterSequence(at: newEnd)
      if range.location < newEnd { newEnd = NSMaxRange(range) }
    }

    oldRange = NSRange(location: prefixLength, length: oldEnd - prefixLength)
    newRange = NSRange(location: prefixLength, length: newEnd - prefixLength)
  }
}

struct AttributedTextReplacementDiff {
  let oldRange: NSRange
  let newRange: NSRange

  init(old: NSAttributedString, new: NSAttributedString, textDiff: TextReplacementDiff) {
    var prefixLength = 0
    let maximumPrefixLength = textDiff.oldRange.location
    while prefixLength < maximumPrefixLength {
      var oldEffectiveRange = NSRange()
      var newEffectiveRange = NSRange()
      let oldAttributes = old.attributes(at: prefixLength, effectiveRange: &oldEffectiveRange)
      let newAttributes = new.attributes(at: prefixLength, effectiveRange: &newEffectiveRange)
      guard (oldAttributes as NSDictionary).isEqual(to: newAttributes) else { break }
      prefixLength = min(
        maximumPrefixLength, NSMaxRange(oldEffectiveRange), NSMaxRange(newEffectiveRange))
    }

    let maximumSuffixLength = old.length - NSMaxRange(textDiff.oldRange)
    var suffixLength = 0
    while suffixLength < maximumSuffixLength {
      let oldLocation = old.length - suffixLength - 1
      let newLocation = new.length - suffixLength - 1
      var oldEffectiveRange = NSRange()
      var newEffectiveRange = NSRange()
      let oldAttributes = old.attributes(at: oldLocation, effectiveRange: &oldEffectiveRange)
      let newAttributes = new.attributes(at: newLocation, effectiveRange: &newEffectiveRange)
      guard (oldAttributes as NSDictionary).isEqual(to: newAttributes) else { break }
      suffixLength += min(
        maximumSuffixLength - suffixLength,
        oldLocation - oldEffectiveRange.location + 1,
        newLocation - newEffectiveRange.location + 1
      )
    }

    oldRange = NSRange(
      location: prefixLength, length: old.length - prefixLength - suffixLength)
    newRange = NSRange(
      location: prefixLength, length: new.length - prefixLength - suffixLength)
  }
}
