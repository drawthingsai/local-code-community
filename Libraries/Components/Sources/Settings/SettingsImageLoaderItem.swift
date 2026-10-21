//Created 11/13/23

import Dflat
import Localization
import PhotosUI
import Style
import UIKit

public struct SettingsImageLoaderItem: SettingsViewObservable {
  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var isIncompatible: Bool = false
  public var value: Bool {
    image != nil
  }
  public private(set) var viewModifying: any SettingsViewModifying
  public var image: UIImage?
  public var title: String?

  public init(
    image: UIImage? = nil, title: String? = nil,
    didTapOpenPhotoPicker: ((PHPickerViewController) -> Void)? = nil,
    phPickerCompletion: ((UIImage?) -> Void)? = nil,
    didRemoveImage: (() -> Void)? = nil
  ) {
    self.image = image
    self.title = title
    self.viewModifying = ViewModifier(
      didTapOpenPhotoPicker: didTapOpenPhotoPicker,
      phPickerCompletion: phPickerCompletion, didRemoveImage: didRemoveImage)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsImageLoaderItem else { return false }
    return image == other.image && isHidden == other.isHidden && title == other.title
      && isEnabled == other.isEnabled && image == other.image
  }
}

extension SettingsImageLoaderItem {
  private final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsImageLoaderItem

    // views
    public var view: UIView?
    public lazy var imageView: UIImageView = {
      let imageView = UIImageView()
      imageView.clipsToBounds = true
      imageView.layer.cornerRadius = 16
      imageView.contentMode = .scaleAspectFill
      return imageView
    }()
    public lazy var addButton: UIButton = {
      makeButton(title: "", image: UIImage(imageLiteralResourceName: "camera"))
    }()
    public lazy var removeButton: UIButton = {
      makeButton(
        title: LocalizedString.forKey("remove"), image: UIImage(imageLiteralResourceName: "trash"))
    }()
    public lazy var changeButton: UIButton = {
      makeButton(
        title: LocalizedString.forKey("change"), image: UIImage(imageLiteralResourceName: "camera"))
    }()

    // actions
    private var didTapOpenPhotoPicker: ((PHPickerViewController) -> Void)?
    private var photoPickerResponder: PhotoPickerResponder
    private var didRemoveImage: (() -> Void)?

    public init(
      didTapOpenPhotoPicker: ((PHPickerViewController) -> Void)? = nil,
      phPickerCompletion: ((UIImage?) -> Void)? = nil,
      didRemoveImage: (() -> Void)? = nil
    ) {
      self.didTapOpenPhotoPicker = didTapOpenPhotoPicker
      self.photoPickerResponder = PhotoPickerResponder(phPickerCompletion: phPickerCompletion)
      self.didRemoveImage = didRemoveImage
    }
    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      // make views and stuff
      let view = UIView()
      self.view = view
      let openPhotoAction = UIAction { [weak self] _ in
        guard let self else { return }
        var configuration = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
        configuration.filter = .images
        let photoPickerViewController = PHPickerViewController(configuration: configuration)
        photoPickerViewController.delegate = self.photoPickerResponder
        self.didTapOpenPhotoPicker?(photoPickerViewController)
      }
      addButton.setTitle(item.title, for: .normal)
      view.addSubview(addButton)
      addButton.snp.makeConstraints { make in
        make.leading.trailing.top.equalToSuperview()
        make.height.equalTo(Theme.current.buttonHeight)
      }
      view.addSubview(imageView)
      imageView.snp.makeConstraints { make in
        make.leading.top.equalToSuperview()
        make.size.equalTo(Theme.current.buttonHeight * 2 + 4)
        make.bottom.equalToSuperview().priority(.medium)
      }
      imageView.image = item.image
      view.addSubview(changeButton)
      changeButton.snp.makeConstraints { make in
        make.leading.equalTo(imageView.snp.trailing).offset(
          Theme.current.sectionItemInternalSpacing)
        make.top.trailing.equalToSuperview()
        make.height.equalTo(Theme.current.buttonHeight)
      }
      view.addSubview(removeButton)
      removeButton.snp.makeConstraints { make in
        make.top.equalTo(changeButton.snp.bottom).offset(Theme.current.sectionItemInternalSpacing)
        make.leading.equalTo(imageView.snp.trailing).offset(
          Theme.current.sectionItemInternalSpacing)
        make.trailing.equalToSuperview()
        make.height.equalTo(Theme.current.buttonHeight)
      }
      switchViews(hasImage: item.image != nil)
      addButton.addAction(openPhotoAction, for: .touchUpInside)
      changeButton.addAction(openPhotoAction, for: .touchUpInside)
      removeButton.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          self.didRemoveImage?()
        }, for: .touchUpInside)
      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      updatingItem.image = newItem.image
      imageView.image = updatingItem.image
      updatingItem.title = newItem.title
      switchViews(hasImage: updatingItem.image != nil)
      addButton.setTitle(updatingItem.title, for: .normal)
      return updatingItem
    }

    private func switchViews(hasImage: Bool) {
      if hasImage {
        imageView.isHidden = false
        changeButton.isHidden = false
        changeButton.isEnabled = true
        removeButton.isHidden = false
        removeButton.isEnabled = true
        addButton.isHidden = true
        addButton.isEnabled = false
        addButton.snp.remakeConstraints { make in
          make.leading.trailing.top.equalToSuperview()
          make.height.equalTo(Theme.current.buttonHeight)
        }
      } else {
        imageView.isHidden = true
        changeButton.isHidden = true
        changeButton.isEnabled = false
        removeButton.isHidden = true
        removeButton.isEnabled = false
        addButton.isHidden = false
        addButton.isEnabled = true
        addButton.snp.remakeConstraints { make in
          make.leading.trailing.top.equalToSuperview()
          make.height.equalTo(Theme.current.buttonHeight)
          make.bottom.equalToSuperview().priority(.high)
        }
      }
    }

    private func makeButton(title: String?, image: UIImage) -> UIButton {
      let button = UIButton(type: .custom)
      var config = UIButton.Configuration.bordered()
      config.baseBackgroundColor = Theme.current.itemBackgroundColor
      config.background.strokeColor = Theme.current.itemBorderColor
      config.baseForegroundColor = Theme.current.rowTitleColor
      config.background.cornerRadius = Theme.current.secondaryItemCornerRadius
      config.image = image.withTintColor(Theme.current.rowTitleColor)
      config.imagePlacement = .trailing
      config.title = title
      config.contentInsets = NSDirectionalEdgeInsets(
        top: 12, leading: Theme.current.secondaryItemCornerRadius, bottom: 12, trailing: 12)
      button.configuration = config
      button.contentHorizontalAlignment = .fill
      button.layer.cornerRadius = Theme.current.secondaryItemCornerRadius
      FontMetrics.default.scaleFont(Theme.current.rowTitleFont, bindTo: button)
      return button
    }
  }
}

fileprivate final class PhotoPickerResponder: PHPickerViewControllerDelegate {
  var phPickerCompletion: ((UIImage?) -> Void)?

  init(phPickerCompletion: ((UIImage?) -> Void)? = nil) {
    self.phPickerCompletion = phPickerCompletion
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    // we don't want to reset the image already loaded when results cancelled
    guard let selectedImage = results.first else { return }
    // We need to log error here. Special-casing for WebP and HEIC here.
    guard
      selectedImage.itemProvider.hasItemConformingToTypeIdentifier(UTType.webP.identifier)
        || selectedImage.itemProvider.canLoadObject(ofClass: UIImage.self)
    else {
      DispatchQueue.main.async {
        self.phPickerCompletion?(nil)
      }
      return
    }
    results.first?.itemProvider.loadDataRepresentation(
      forTypeIdentifier: UTType.image.identifier,
      completionHandler: { [weak self] data, error in
        DispatchQueue.main.async {
          guard let self else { return }
          if let data {
            self.phPickerCompletion?(UIImage(data: data))
          }
        }
      })
  }
}
