import Features
import Style
import UIKit

public struct Theme {
  // overall
  public let individualStackViewItemSpacing: CGFloat
  public let stackViewItemSpacing: CGFloat
  public let itemBackgroundColor: UIColor
  public let itemCornerRadius: CGFloat
  public let secondaryItemCornerRadius: CGFloat  // wiz only rows such as model/lora
  public let itemBorderColor: UIColor
  public let sectionIconColor: UIColor
  public let sectionTitleMargin: CGFloat  // leading trailing margin from superview to section title
  public let sectionContentMargin: CGFloat  // leading trailing margin from superview to content
  public let sectionItemInternalSpacing: CGFloat
  public let textImagePadding: CGFloat

  // texts
  public let sectionTitleColor: UIColor
  public let sectionTitleFont: UIFont
  public let sectionDescriptionColor: UIColor  // expandable detail
  public let sectionDescriptionFont: UIFont
  public let rowTitleColor: UIColor  // enable and various one liner items
  public let rowTitleFont: UIFont
  public let primaryContentFont: UIFont  // mostly buttons
  public let primaryContentColor: UIColor
  public let primaryContentBackgroundColor: UIColor
  public let secondaryContentFont: UIFont  // tiny text above slider, buttons
  public let secondaryContentColor: UIColor
  public let tertiaryContentFont: UIFont  // wiz only even smaller trailling text next to secondary text
  public let tertiaryContentColor: UIColor

  // specific items
  // section bordering
  public let sectionBorderRadius: CGFloat
  public let sectionBorderWidth: CGFloat
  public let sectionBorderColor: UIColor
  public let sectionLayoutMargin: UIEdgeInsets
  // button item
  public let buttonDividerColor: UIColor
  public let buttonHeight: CGFloat
  // image aspect ratio size item
  public let highlightColor: UIColor  // selected aspect ratio
  public let highlightBackgroundColor: UIColor  // selected aspect ratio background
  public let aspectRatioItemContentColor: UIColor
  public let aspectRatioTitleFont: UIFont
  // segmented control
  public let segmentedControlForegroundColor: UIColor
  public let segmentedControlSelectedForegroundColor: UIColor
  public let segmentedControlSelectedSegmentTintColor: UIColor
  public let segmentedControlBackgroundColor: UIColor
  public let segmentedControlFont: UIFont
  public let segmentedControlHeight: CGFloat
  // image item
  public let imageItemBackgroundCornerRadius: CGFloat
  public let imageItemContentCornerRadius: CGFloat
  public let imageItemBorderColor: UIColor
  // slider item
  public let controlOnTintColor: UIColor  // active track color
  public let sliderMaximumTrackTintColor: UIColor  // inactive track color
}

extension Theme {
  public static var current: Theme {
    FeatureFlags.WizFeatures ? wiz : drawThings
  }
  public static var drawThings: Theme =
    Theme(
      individualStackViewItemSpacing: UIDevice.current.userInterfaceIdiom == .phone ? 8 : 12,
      stackViewItemSpacing: 8,
      itemBackgroundColor: .secondaryBackground,
      itemCornerRadius: 8,
      secondaryItemCornerRadius: 8,
      itemBorderColor: .primaryBorder,
      sectionIconColor: .senaryText,
      sectionTitleMargin: 12,
      sectionContentMargin: 12,
      sectionItemInternalSpacing: 8,
      textImagePadding: 8,
      sectionTitleColor: .secondaryText,
      sectionTitleFont: .systemFont(ofSize: 14, weight: .semibold),
      sectionDescriptionColor: .quaternaryText,
      sectionDescriptionFont: .systemFont(ofSize: 11),
      rowTitleColor: .secondaryText,
      rowTitleFont: .systemFont(ofSize: 14, weight: .medium),
      primaryContentFont: .systemFont(ofSize: 14),
      primaryContentColor: .tertiaryText,
      primaryContentBackgroundColor: .tertiaryFill,
      secondaryContentFont: .systemFont(ofSize: 11, weight: .medium),
      secondaryContentColor: .senaryText,
      tertiaryContentFont: .systemFont(ofSize: 11),
      tertiaryContentColor: .senaryText,
      sectionBorderRadius: 16,
      sectionBorderWidth: 1,
      sectionBorderColor: .primaryBorder,
      sectionLayoutMargin: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
      buttonDividerColor: .tertiaryBorder,
      buttonHeight: 40,
      highlightColor: .primaryFill,
      highlightBackgroundColor: .tertiaryBackground,
      aspectRatioItemContentColor: .quaternaryBorder,
      aspectRatioTitleFont: .systemFont(ofSize: 13),
      segmentedControlForegroundColor: .senaryText,
      segmentedControlSelectedForegroundColor: .primaryText,
      segmentedControlSelectedSegmentTintColor: .senaryFill,
      segmentedControlBackgroundColor: .quaternaryFillA,
      segmentedControlFont: .systemFont(ofSize: 14, weight: .medium),
      segmentedControlHeight: 32,
      imageItemBackgroundCornerRadius: 23,
      imageItemContentCornerRadius: 15,
      imageItemBorderColor: .secondaryBorder,
      controlOnTintColor: .primaryColor,
      sliderMaximumTrackTintColor: .secondaryFill
    )
  public static var wiz: Theme = Theme(
    individualStackViewItemSpacing: 12,
    stackViewItemSpacing: 8,
    itemBackgroundColor: .secondaryBackground,  // denary fill is the same as secondary background
    itemCornerRadius: 24,
    secondaryItemCornerRadius: 16,
    itemBorderColor: .primaryBorder,
    sectionIconColor: .senaryText,
    sectionTitleMargin: 16,
    sectionContentMargin: 32,
    sectionItemInternalSpacing: 12,
    textImagePadding: 8,
    sectionTitleColor: .secondaryText,
    sectionTitleFont: .systemFont(ofSize: 14, weight: .medium),
    sectionDescriptionColor: .senaryText,
    sectionDescriptionFont: .systemFont(ofSize: 14),
    rowTitleColor: .senaryText,
    rowTitleFont: .systemFont(ofSize: 16, weight: .medium),
    primaryContentFont: .systemFont(ofSize: 20, weight: .semibold),
    primaryContentColor: .senaryText,
    primaryContentBackgroundColor: .tertiaryFill,
    secondaryContentFont: .systemFont(ofSize: 12),
    secondaryContentColor: .senaryText,
    tertiaryContentFont: .systemFont(ofSize: 12, weight: .light),
    tertiaryContentColor: .senaryText,
    sectionBorderRadius: 0,
    sectionBorderWidth: 0,
    sectionBorderColor: .primaryBorder,
    sectionLayoutMargin: .zero,
    buttonDividerColor: .tertiaryBorder,
    buttonHeight: 48,
    // unchanged and not sure if we need to change these for wiz due to lack of design
    highlightColor: .primaryFill,
    highlightBackgroundColor: .tertiaryBackground,
    aspectRatioItemContentColor: .quaternaryBorder,
    aspectRatioTitleFont: .systemFont(ofSize: 13),
    segmentedControlForegroundColor: .senaryText,
    segmentedControlSelectedForegroundColor: .primaryText,
    segmentedControlSelectedSegmentTintColor: .senaryFill,
    segmentedControlBackgroundColor: .quaternaryFillA,
    segmentedControlFont: .systemFont(ofSize: 14, weight: .medium),
    segmentedControlHeight: 32,
    imageItemBackgroundCornerRadius: 23,
    imageItemContentCornerRadius: 15,
    imageItemBorderColor: .secondaryBorder,
    controlOnTintColor: .primaryColor,
    sliderMaximumTrackTintColor: .secondaryFill
  )
}
