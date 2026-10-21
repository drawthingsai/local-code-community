#if canImport(UIKit)
  import Foundation
  import UIKit

  extension UIKitMarkdownStyler {
    static func styleTaskCheckboxes(
      text: String,
      nsText: NSString,
      selectionRange: NSRange,
      selectionSuppressed: Bool,
      codeTokens: [MarkdownToken],
      result: NSMutableAttributedString,
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) {
      let fullRange = NSRange(location: 0, length: nsText.length)
      let taskMatches = MarkdownTaskCheckboxParser.matches(in: text, range: fullRange)
      for match in taskMatches {
        let markerRange = match.markerRange
        let spacerRange = match.spacerRange
        let checkboxRange = match.checkboxRange
        if MarkdownDetection.isInsideCodeBlock(range: checkboxRange, codeTokens: codeTokens) {
          continue
        }

        if match.isChecked {
          let lineRange = nsText.lineRange(for: checkboxRange)
          var lineEnd = NSMaxRange(lineRange)
          if lineEnd > lineRange.location {
            let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
            if nsText.substring(with: lastCharRange) == "\n" {
              lineEnd -= 1
            }
          }
          var contentStart = NSMaxRange(checkboxRange)
          while contentStart < lineEnd {
            let charRange = NSRange(location: contentStart, length: 1)
            let char = nsText.substring(with: charRange)
            if char == " " || char == "\t" {
              contentStart += 1
              continue
            }
            break
          }
          if contentStart < lineEnd {
            add(
              [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: configuration.theme.strikethroughColor,
              ],
              NSRange(location: contentStart, length: lineEnd - contentStart),
              result
            )
          }
        }

        if !selectionSuppressed,
          selectionRange.length == 0,
          let syntaxRange = MarkdownTaskCheckboxParser.syntaxRange(
            at: selectionRange.location,
            in: text
          ),
          NSIntersectionRange(syntaxRange, checkboxRange).length > 0
        {
          continue
        }

        let afterCheckboxIndex = NSMaxRange(checkboxRange)
        if afterCheckboxIndex < nsText.length {
          let spaceRange = NSRange(location: afterCheckboxIndex, length: 1)
          let spaceChar = nsText.substring(with: spaceRange)
          if spaceChar == " " && !match.isChecked {
            let extraSpacing = max(
              configuration.taskCheckbox.minimumExtraSpacing,
              ceil(
                baseFont.pointSize
                  * configuration.taskCheckbox.extraSpacingPerFontPointFraction)
            )
            add([.kern: extraSpacing], spaceRange, result)
          }
        }

        if markerRange.location != NSNotFound {
          add([.foregroundColor: UIColor.clear], markerRange, result)
        }
        if spacerRange.location != NSNotFound {
          add([.foregroundColor: UIColor.clear], spacerRange, result)
        }
        add(
          [
            .taskCheckbox: match.isChecked,
            .foregroundColor: UIColor.clear,
          ],
          checkboxRange,
          result
        )
      }
    }

    private static func add(
      _ attrs: [NSAttributedString.Key: Any],
      _ range: NSRange,
      _ result: NSMutableAttributedString
    ) {
      guard range.location >= 0, NSMaxRange(range) <= result.length, range.length > 0 else {
        return
      }
      result.addAttributes(attrs, range: range)
    }
  }
#endif
