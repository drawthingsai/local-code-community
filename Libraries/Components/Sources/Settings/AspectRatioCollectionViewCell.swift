//
//  AspectRatioCollectionViewCell.swift
//  DrawThings
//
//  Created by Gong Chen on 10/19/23.
//

import Foundation
import Style
import UIKit

public final class AspectRatioCollectionViewCell: UICollectionViewCell {
  public struct ViewModel: Hashable & Equatable {
    public var aspectRatio: AspectRatio
    public init(aspectRatio: AspectRatio) {
      self.aspectRatio = aspectRatio
    }
  }
  public static var reusableIdentifier: String {
    "AspectRatioCollectionViewCell"
  }

  private func color() -> UIColor {
    // TODO: update color to fills color
    return isSelected ? Theme.current.highlightBackgroundColor : Theme.current.itemBackgroundColor
  }

  public let demoView: UIView = {
    let view = UIView()
    view.layer.borderWidth = 1
    view.layer.cornerRadius = 3
    view.clipsToBounds = true
    view.backgroundColor = .clear
    return view
  }()

  private let titleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    FontMetrics.default.scaleFont(Theme.current.aspectRatioTitleFont, bindTo: label)
    return label
  }()

  public override init(frame: CGRect) {
    super.init(frame: frame)
    self.backgroundConfiguration = UIBackgroundConfiguration.listPlainCell()
    contentView.addSubview(titleLabel)
    contentView.addSubview(demoView)
    titleLabel.snp.makeConstraints { make in
      make.bottom.equalToSuperview().offset(-5)
      make.centerX.equalToSuperview()
    }
    demoView.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(10)
      make.height.width.equalTo(50)
      make.centerX.equalToSuperview()
    }
    titleLabel.textColor = color()
    demoView.layer.borderColor = color().cgColor
    self.layer.cornerRadius = Theme.current.itemCornerRadius
    self.clipsToBounds = true
    self.configurationUpdateHandler = { cell, state in
      guard let cell = cell as? AspectRatioCollectionViewCell else { return }
      if state.isSelected {
        cell.contentView.backgroundColor = Theme.current.highlightBackgroundColor
        cell.demoView.layer.borderColor = Theme.current.highlightColor.cgColor
        cell.titleLabel.textColor = Theme.current.highlightColor
      } else {
        cell.contentView.backgroundColor = Theme.current.itemBackgroundColor
        cell.demoView.layer.borderColor = Theme.current.aspectRatioItemContentColor.cgColor
        cell.titleLabel.textColor = Theme.current.aspectRatioItemContentColor
      }
    }
  }
  required init?(coder: NSCoder) {
    fatalError()
  }

  public func setViewModel(_ viewModel: ViewModel) {
    titleLabel.text = viewModel.aspectRatio.description
    var width: CGFloat = 50
    var height: CGFloat = 50
    switch viewModel.aspectRatio {
    case .oneToOne:
      break
    case .oneToTwo:
      width = 25
    case .twoToThree:
      width = 33
    case .fourToFive:
      width = 40
    case .fiveToFour:
      height = 40
    case .threeToFour:
      width = 38
    case .fourToThree:
      height = 38
    case .threeToTwo:
      height = 33
    case .twoToOne:
      height = 25
    case .sixteenToNine:
      height = 28
    case .nineToSixteen:
      width = 28
    }
    guard demoView.frame.size != CGSize(width: width, height: height) else { return }
    demoView.snp.updateConstraints { make in
      make.width.equalTo(width)
      make.height.equalTo(height)
      make.top.equalToSuperview().offset(10 + (50 - height) / 2)
    }
  }
}
