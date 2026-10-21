import DataModels
import Dflat
import Foundation
import Localization
import SnapKit
import Style
import UIKit

public enum AspectRatio: CaseIterable & CustomStringConvertible & Equatable {
  case oneToTwo
  case twoToThree
  case threeToFour
  case fourToFive
  case oneToOne
  case fiveToFour
  case fourToThree
  case threeToTwo
  case twoToOne
  case sixteenToNine
  case nineToSixteen

  public var value: Float {
    switch self {
    case .oneToOne:
      return 1
    case .oneToTwo:
      return 1.0 / 2
    case .twoToThree:
      return 2.0 / 3
    case .fourToFive:
      return 4.0 / 5
    case .fiveToFour:
      return 5.0 / 4
    case .threeToFour:
      return 3.0 / 4
    case .fourToThree:
      return 4.0 / 3
    case .threeToTwo:
      return 3.0 / 2
    case .twoToOne:
      return 2.0 / 1
    case .nineToSixteen:
      return 9.0 / 16
    case .sixteenToNine:
      return 16.0 / 9
    }
  }

  public var description: String {
    switch self {
    case .oneToOne:
      return "1:1"
    case .oneToTwo:
      return "1:2"
    case .twoToThree:
      return "2:3"
    case .fourToFive:
      return "4:5"
    case .fiveToFour:
      return "5:4"
    case .threeToFour:
      return "3:4"
    case .fourToThree:
      return "4:3"
    case .threeToTwo:
      return "3:2"
    case .twoToOne:
      return "2:1"
    case .nineToSixteen:
      return "9:16"
    case .sixteenToNine:
      return "16:9"
    }
  }

  public static func fromString(_ string: String) -> AspectRatio? {
    switch string {
    case "1:1":
      return .oneToOne
    case "1:2":
      return .oneToTwo
    case "2:3":
      return .twoToThree
    case "4:5":
      return .fourToFive
    case "5:4":
      return .fiveToFour
    case "3:4":
      return .threeToFour
    case "4:3":
      return .fourToThree
    case "3:2":
      return .threeToTwo
    case "2:1":
      return .twoToOne
    case "9:16":
      return .nineToSixteen
    case "16:9":
      return .sixteenToNine
    default:
      return nil
    }
  }

  public static func findMostMatchingAspectRatio(_ value: Float, ratios: [AspectRatio])
    -> AspectRatio
  {
    let closest = ratios.min(by: { abs($0.value - value) < abs($1.value - value) })
    return closest ?? .oneToOne  // Default to 1:1 if collection is somehow empty
  }
}

public enum AspectRatioSize: String {
  case small = "small"
  case normal = "normal"
  case large = "large"
}

public struct ImageSizeComplex: Equatable {
  public let scale: DeviceCapability.Scale
  public let defaultScale: UInt16
  public init(scale: DeviceCapability.Scale, defaultScale: UInt16) {
    self.scale = scale
    self.defaultScale = defaultScale
  }
}

extension SettingsAspectRatioItem {
  final class ViewModifier: SettingsViewModifying {

    public typealias Item = SettingsAspectRatioItem

    public var view: UIView?

    final class CollectionViewResponder: NSObject & UICollectionViewDelegate {
      var viewModels: [AspectRatioCollectionViewCell.ViewModel]
      var handleAspectRatioSelected: (AspectRatio) -> Void
      init(handleAspectRatioSelected: @escaping (AspectRatio) -> Void) {
        self.handleAspectRatioSelected = handleAspectRatioSelected
        viewModels = []
        super.init()
      }
      func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
      {
        guard indexPath.item >= 0 && indexPath.item < viewModels.count else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
        handleAspectRatioSelected(viewModels[indexPath.item].aspectRatio)
      }
    }

    public var collectionView: UICollectionView? = nil
    private var collectionViewResponder: CollectionViewResponder
    private var collectionViewDiffableDataSource:
      UICollectionViewDiffableDataSource<Int, AspectRatioCollectionViewCell.ViewModel>?

    public init(handleAspectRatioSelected: @escaping (AspectRatio) -> Void, hideView: Bool) {
      self.collectionViewResponder = CollectionViewResponder(
        handleAspectRatioSelected: handleAspectRatioSelected)
      self.hideView = hideView
    }

    public func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let view = UIView()
      self.view = view
      let layout = UICollectionViewFlowLayout()
      layout.scrollDirection = .horizontal
      layout.itemSize = CGSize(width: 80, height: 90)
      layout.minimumInteritemSpacing = 10
      let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
      self.collectionView = collectionView
      collectionView.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
      collectionView.showsVerticalScrollIndicator = false
      collectionView.showsHorizontalScrollIndicator = false
      collectionView.allowsMultipleSelection = false
      collectionView.delegate = collectionViewResponder
      collectionView.backgroundColor = Theme.current.itemBackgroundColor
      collectionView.register(
        AspectRatioCollectionViewCell.self,
        forCellWithReuseIdentifier: AspectRatioCollectionViewCell.reusableIdentifier)
      // Below are string "_setSupportsPointerDragScrolling:"
      let mysteriousSecret = [
        106_488_813, 106_488_839, 106_488_855, 106_488_840, 106_488_809, 106_488_845, 106_488_842,
        106_488_844, 106_488_845, 106_488_850, 106_488_854, 106_488_855, 106_488_826, 106_488_859,
        106_488_851, 106_488_862, 106_489_030, 106_488_853, 106_489_032, 106_488_824, 106_489_032,
        106_488_857, 106_488_869, 106_488_879, 106_488_865, 106_489_042, 106_489_045, 106_489_040,
        106_489_046, 106_489_041, 106_489_052, 106_489_043, 106_488_840,
      ].enumerated().map({
        (($1 + 32 - $0) ^ 106_488_914) - $0
      }).map { String(UnicodeScalar($0)!) }.joined()
      let selector = NSSelectorFromString(mysteriousSecret)
      collectionView.perform(selector, with: true)
      collectionViewDiffableDataSource = UICollectionViewDiffableDataSource<
        Int, AspectRatioCollectionViewCell.ViewModel
      >(collectionView: collectionView) { collectionView, indexPath, viewModel in
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: AspectRatioCollectionViewCell.reusableIdentifier,
            for: indexPath) as! AspectRatioCollectionViewCell
        cell.setViewModel(viewModel)
        return cell
      }
      view.addSubview(collectionView)
      collectionView.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.leading.trailing.equalToSuperview().inset(-8)
        make.height.equalTo(90)
      }
      collectionViewResponder.viewModels = item.aspectRatioViewModels
      var snapshot = NSDiffableDataSourceSnapshot<Int, AspectRatioCollectionViewCell.ViewModel>()
      snapshot.appendSections([0])
      snapshot.appendItems(collectionViewResponder.viewModels, toSection: 0)
      collectionViewDiffableDataSource?.apply(snapshot)
      selectAspectRatio(nil, with: item, animated: false)
      return ([view], self)
    }

    private func selectAspectRatio(
      _ updatingItem: SettingsAspectRatioItem?, with newItem: SettingsAspectRatioItem,
      animated: Bool
    ) {
      let selectIndex: IndexPath?
      if let aspectRatio = newItem.value,
        let selectableAspectRatio = newItem.aspectRatios.firstIndex(of: aspectRatio)
      {
        selectIndex = IndexPath(item: selectableAspectRatio, section: 0)
      } else {
        selectIndex = nil
      }
      let deselectIndex: IndexPath?
      if let aspectRatio = updatingItem?.value,
        let deselectableAspectRatio = updatingItem?.aspectRatios.firstIndex(of: aspectRatio)
      {
        deselectIndex = IndexPath(item: deselectableAspectRatio, section: 0)
      } else {
        deselectIndex = nil
      }
      if let collectionView = collectionView {
        DispatchQueue.main.async { [weak collectionViewResponder] in
          guard let collectionViewResponder = collectionViewResponder else { return }
          if let deselectIndex = deselectIndex,
            deselectIndex.item >= 0 && deselectIndex.item < collectionViewResponder.viewModels.count
          {
            collectionView.deselectItem(at: deselectIndex, animated: animated)
          }
          if let selectIndex = selectIndex,
            selectIndex.item >= 0 && selectIndex.item < collectionViewResponder.viewModels.count
          {
            collectionView.selectItem(
              at: selectIndex, animated: animated, scrollPosition: .centeredHorizontally)
          }
        }
      }
    }

    public func updateViews(
      _ updatingItem: SettingsAspectRatioItem,
      with newItem: SettingsAspectRatioItem
    ) -> SettingsAspectRatioItem {
      var updatingItem = updatingItem
      guard
        updatingItem.value != newItem.value || updatingItem.aspectRatios != newItem.aspectRatios
          || updatingItem.isHidden != newItem.isHidden
      else { return updatingItem }
      let aspectRatiosUpdated: Bool
      if updatingItem.aspectRatios != newItem.aspectRatios {
        collectionViewResponder.viewModels = newItem.aspectRatioViewModels
        var snapshot = NSDiffableDataSourceSnapshot<Int, AspectRatioCollectionViewCell.ViewModel>()
        snapshot.appendSections([0])
        snapshot.appendItems(collectionViewResponder.viewModels, toSection: 0)
        collectionViewDiffableDataSource?.apply(snapshot)
        updatingItem.aspectRatios = newItem.aspectRatios
        aspectRatiosUpdated = true
      } else {
        aspectRatiosUpdated = false
      }
      if updatingItem.value != newItem.value || aspectRatiosUpdated {
        selectAspectRatio(updatingItem, with: newItem, animated: true)
      }
      updatingItem.value = newItem.value
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }
  }
}

public struct SettingsAspectRatioItem: SettingsViewObservable {
  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public private(set) var viewModifying: any SettingsViewModifying
  public var value: AspectRatio?
  public var aspectRatios: [AspectRatio]
  private var defaultScale: UInt16 = 1

  private var aspectRatioViewModels: [AspectRatioCollectionViewCell.ViewModel] {
    return aspectRatios.map {
      AspectRatioCollectionViewCell.ViewModel(aspectRatio: $0)
    }
  }

  public init(
    imageSizeComplex: ImageSizeComplex, selectedSize: AspectRatioSize?,
    aspectRatios: [AspectRatio] = AspectRatio.allCases,
    handleAspectRatioSelected: @escaping (AspectRatio) -> Void, hideView: Bool = false
  ) {
    self.value = Self.findAspectRatio(
      from: imageSizeComplex, selectedSize: selectedSize, aspectRatios: aspectRatios)
    self.aspectRatios = aspectRatios
    self.viewModifying = ViewModifier(
      handleAspectRatioSelected: handleAspectRatioSelected, hideView: hideView)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsAspectRatioItem else { return false }
    return value == other.value && isHidden == other.isHidden && isEnabled == other.isEnabled
      && aspectRatios == other.aspectRatios
  }
}

extension SettingsAspectRatioItem {
  public static func findAspectRatio(
    from sizeComplex: ImageSizeComplex, selectedSize: AspectRatioSize?,
    aspectRatios: [AspectRatio] = AspectRatio.allCases
  ) -> AspectRatio? {
    let scale = sizeComplex.scale
    guard
      let aspectRatio =
        (selectedSize.flatMap {
          let selectedSize = findSize(for: $0, defaultScale: sizeComplex.defaultScale)
          return aspectRatios.first {
            let size = Self.aspectRatioSize(from: selectedSize, aspectRatio: $0)
            return size.0 == scale.widthScale && size.1 == scale.heightScale
          }
        })
        ?? (aspectRatios.first {
          abs(Float(scale.widthScale) / Float(scale.heightScale) - $0.value) < 0.05
        })
    else { return nil }
    return aspectRatio
  }
  public static func aspectRatioSize(from size: UInt16, aspectRatio: AspectRatio) -> (
    UInt16, UInt16
  ) {
    var widthRatio: Float
    var heightRatio: Float
    switch aspectRatio {
    case .oneToOne:
      widthRatio = 1
      heightRatio = 1
    case .oneToTwo:
      widthRatio = 1
      heightRatio = 2
    case .twoToThree:
      widthRatio = 2
      heightRatio = 3
    case .fourToFive:
      widthRatio = 4
      heightRatio = 5
    case .fiveToFour:
      widthRatio = 5
      heightRatio = 4
    case .threeToFour:
      widthRatio = 3
      heightRatio = 4
    case .fourToThree:
      widthRatio = 4
      heightRatio = 3
    case .threeToTwo:
      widthRatio = 3
      heightRatio = 2
    case .twoToOne:
      widthRatio = 2
      heightRatio = 1
    case .nineToSixteen:
      widthRatio = 9
      heightRatio = 16
    case .sixteenToNine:
      widthRatio = 16
      heightRatio = 9
    }
    let area = Int(size) * Int(size)
    let scale = (Float(area) / (widthRatio * heightRatio)).squareRoot()
    // First try to floor scale and then multiply back
    let firstWidth = UInt16(scale.rounded(.down) * widthRatio)
    let firstHeight = UInt16(scale.rounded(.down) * heightRatio)
    if max(firstWidth, firstHeight) >= size {
      return (firstWidth, firstHeight)
    }
    // Otherwise, we will round down after multiply (approximate aspect ratio).
    let secondWidth = UInt16((scale * widthRatio).rounded())
    let secondHeight = UInt16((scale * heightRatio).rounded())
    return (secondWidth, secondHeight)
  }

  public static func findSize(for size: AspectRatioSize, defaultScale: UInt16) -> UInt16 {
    switch size {
    case .small:
      return min(max(defaultScale - 4, 6), defaultScale - 1)
    case .normal:
      return defaultScale
    case .large:
      return defaultScale + 4
    }
  }
}
