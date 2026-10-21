import Foundation
import Localization
import Style
import UIKit

public enum ItemViewModelDisplayThumbnail: Hashable & Equatable {
  case thumbnailPath(String)
  case imageLiteralResourceName(String)
}

public enum ItemDisplayTitle: Hashable & Equatable {
  case title(String)
  case attributed(NSAttributedString)
  var titleString: String {
    switch self {
    case .title(let title):
      return title
    case .attributed(let attributed):
      return attributed.string
    }
  }
}

public struct ItemViewModel: Hashable & Equatable {
  public struct ItemFlag: OptionSet, Hashable & Equatable {
    public let rawValue: Int

    public static let compatible = ItemFlag(rawValue: 1 << 0)  // 1
    public init(rawValue: Int) {
      self.rawValue = rawValue
    }
  }

  public enum ItemIdentifier: Hashable & Equatable {
    case manage
    case empty
    case action(Int)
    case identifier(AnyHashable)
  }
  var itemIdentifier: ItemIdentifier

  var title: ItemDisplayTitle
  var detail: String

  var thumbnail: ItemViewModelDisplayThumbnail
  var isList: Bool
  var flag: ItemFlag
  public init(
    itemIdentifier: ItemIdentifier, title: ItemDisplayTitle,
    detail: String,
    thumbnail: ItemViewModelDisplayThumbnail, isList: Bool, flag: ItemFlag = [.compatible]
  ) {
    self.itemIdentifier = itemIdentifier
    self.title = title
    self.detail = detail
    self.thumbnail = thumbnail
    self.isList = isList
    self.flag = flag
  }

  public init(viewModel: ItemViewModel, isList: Bool) {
    self.itemIdentifier = viewModel.itemIdentifier
    self.title = viewModel.title
    self.detail = viewModel.detail
    self.thumbnail = viewModel.thumbnail
    self.isList = isList
    self.flag = viewModel.flag
  }
}

public enum ItemAcronymViewModelDisplayThumbnail: Hashable & Equatable {
  case image(UIImage)
  case imageLiteralResourceName(String)
  case systemName(String)
  case acronymTitle(String)
}

public struct ItemAcronymViewModel: Hashable & Equatable {
  var itemIdentifier: ItemViewModel.ItemIdentifier

  var title: ItemDisplayTitle
  var detail: String
  // A short secondary line under the detail, such as a model's download size.
  var caption: String
  var backgroundColor: UIColor

  var thumbnail: ItemAcronymViewModelDisplayThumbnail
  var thumbnailContentMode: UIView.ContentMode?
  var thumbnailTintColor: UIColor?
  var isList: Bool
  var canExport: Bool
  var canDelete: Bool
  var isDownloaded: Bool?
  var file: String?
  var isFP16: Bool?
  var is8Bit: Bool?
  var canQuantize: Bool?
  var isExternalStore: Bool?
  var isInExternalUrl: Bool?
  var flag: ItemViewModel.ItemFlag
  public init(
    itemIdentifier: ItemViewModel.ItemIdentifier, title: ItemDisplayTitle, backgroundColor: UIColor,
    detail: String, caption: String = "",
    thumbnail: ItemAcronymViewModelDisplayThumbnail, isList: Bool, canExport: Bool = false,
    canDelete: Bool = false, isDownloaded: Bool? = nil,
    file: String? = nil, isFP16: Bool? = nil, is8Bit: Bool? = nil, canQuantize: Bool? = nil,
    thumbnailContentMode: UIView.ContentMode? = nil, thumbnailTintColor: UIColor? = nil,
    isExternalStore: Bool? = nil, isInExternalUrl: Bool? = nil,
    flag: ItemViewModel.ItemFlag = [.compatible]
  ) {
    self.itemIdentifier = itemIdentifier
    self.title = title
    self.backgroundColor = backgroundColor
    self.detail = detail
    self.caption = caption
    self.thumbnail = thumbnail
    self.isList = isList
    self.canExport = canExport
    self.canDelete = canDelete
    self.isDownloaded = isDownloaded
    self.file = file
    self.isFP16 = isFP16
    self.is8Bit = is8Bit
    self.canQuantize = canQuantize
    self.thumbnailContentMode = thumbnailContentMode
    self.thumbnailTintColor = thumbnailTintColor
    self.isExternalStore = isExternalStore
    self.isInExternalUrl = isInExternalUrl
    self.flag = flag
  }

  public init(viewModel: ItemAcronymViewModel, isList: Bool) {
    self.itemIdentifier = viewModel.itemIdentifier
    self.title = viewModel.title
    self.backgroundColor = viewModel.backgroundColor
    self.detail = viewModel.detail
    self.caption = viewModel.caption
    self.thumbnail = viewModel.thumbnail
    self.thumbnailTintColor = viewModel.thumbnailTintColor
    self.isList = isList
    self.canExport = viewModel.canExport
    self.canDelete = viewModel.canDelete
    self.flag = viewModel.flag
  }
}

public enum ItemDisplayCollectionViewCellViewModel: Hashable & Equatable {
  case itemViewModel(ItemViewModel)
  case itemAcronymViewModel(ItemAcronymViewModel)

  var flag: ItemViewModel.ItemFlag {
    switch self {
    case .itemAcronymViewModel(let gridAcronymViewModel):
      return gridAcronymViewModel.flag
    case .itemViewModel(let listViewModel):
      return listViewModel.flag
    }
  }

  var titleString: String {
    switch self {
    case .itemAcronymViewModel(let gridAcronymViewModel):
      return gridAcronymViewModel.title.titleString

    case .itemViewModel(let listViewModel):
      return listViewModel.title.titleString
    }
  }

  var itemIdentifier: ItemViewModel.ItemIdentifier {
    switch self {
    case .itemAcronymViewModel(let itemAcronymViewModel):
      return itemAcronymViewModel.itemIdentifier
    case .itemViewModel(let itemViewModel):
      return itemViewModel.itemIdentifier
    }
  }

  // "Stable Diffusion" --> "SD"
  static func acronymTitle(title: String) -> String {
    let filteredInput = title.filter { $0 != "(" && $0 != ")" }
    let components = filteredInput.components(separatedBy: CharacterSet(charactersIn: "- "))
    let firstTwoComponents = components.prefix(2)
    let acronym = firstTwoComponents.compactMap { $0.first?.uppercased() }.joined()
    return acronym
  }

  static func textToUIColor(_ text: String) -> UIColor {
    let index = text.utf8.reduce(0) { partialResult, byte in
      partialResult &* 31 &+ Int(byte)
    }
    return UIColor.paletteForIndex(index)
  }

  static func updateViewModels(
    from items: [ItemDisplayCollectionViewCellViewModel], isListView: Bool
  ) -> [ItemDisplayCollectionViewCellViewModel] {
    return items.map { item in
      switch item {
      case .itemAcronymViewModel(let viewModel):
        let updatedViewModel = ItemAcronymViewModel(viewModel: viewModel, isList: isListView)
        return ItemDisplayCollectionViewCellViewModel.itemAcronymViewModel(updatedViewModel)

      case .itemViewModel(let viewModel):
        let updatedViewModel = ItemViewModel(viewModel: viewModel, isList: isListView)
        return ItemDisplayCollectionViewCellViewModel.itemViewModel(updatedViewModel)

      }
    }
  }
}

public enum ItemDisplaySectionIdentity: Equatable & Hashable {
  public enum KeyOrTitle: Equatable & Hashable {
    case key(_ key: String)
    case title(_ title: String)
    public var description: String {
      switch self {
      case .key(let key):
        return LocalizedString.forKey(key)
      case .title(let title):
        return title
      }
    }
  }
  case noSection
  case section(
    name: KeyOrTitle, image: String?, disambiguator: Int = 0, isCollapsible: Bool = false,
    isCollapsed: Bool = false)

  public func withCollapsedState(_ collapsed: Bool) -> ItemDisplaySectionIdentity {
    switch self {
    case .noSection:
      return self
    case .section(let name, let image, let disambiguator, let isCollapsible, _):
      return .section(
        name: name, image: image, disambiguator: disambiguator, isCollapsible: isCollapsible,
        isCollapsed: collapsed)
    }
  }
}

public struct ItemDisplaySectionModel: Equatable & Hashable {
  public var identifier: ItemDisplaySectionIdentity
  public var items: [ItemDisplayCollectionViewCellViewModel]
}

public enum ItemAcronymSectionIdentity: Equatable & Hashable {
  case noSection
  case section(name: String, image: String?, detail: String)
}

public struct ItemAcronymSectionModel: Equatable & Hashable {
  public var identifier: ItemAcronymSectionIdentity
  public var items: [ItemAcronymViewModel]
}
