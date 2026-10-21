import Dflat
import Style
import UIKit

public final class SectionHeaderView: UICollectionReusableView {
  public struct ViewModel: Hashable & Equatable {
    public var title: String
    public var detail: String
    public var lookUpKey: String
    public init(title: String, detail: String, lookUpKey: String) {
      self.title = title
      self.detail = detail
      self.lookUpKey = lookUpKey
    }
  }
  public override init(frame: CGRect) {
    super.init(frame: frame)
  }
  required init?(coder: NSCoder) {
    fatalError()
  }
  private var stackView: UIStackView? = nil
  private var detailView: UIView? = nil
  private var detailLabel: UILabel? = nil
  private var titleView: UILabel? = nil
  private var toolTipController: ToolTipAndDetailAppearanceController? = nil
  private var viewModel: ViewModel? = nil
  public static let reusableIdentifier = "SectionHeaderView"
  public func setViewModel(
    _ viewModel: ViewModel, workspace: Workspace,
    invalidateLayout: @escaping () -> Void
  ) {
    guard self.viewModel != viewModel else { return }
    self.viewModel = viewModel
    backgroundColor = Theme.current.itemBackgroundColor
    if stackView == nil {
      let stackView = UIStackView()
      stackView.axis = .vertical
      stackView.distribution = .equalSpacing
      stackView.alignment = .fill
      stackView.spacing = Theme.current.stackViewItemSpacing
      self.stackView = stackView
      addSubview(stackView)
      stackView.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(Theme.current.stackViewItemSpacing)
        make.trailing.leading.equalToSuperview()
        make.bottom.equalToSuperview().offset(-Theme.current.stackViewItemSpacing)
      }
    }
    guard let stackView = stackView else { return }
    if let titleView = titleView {
      stackView.removeArrangedSubview(titleView)
      titleView.removeFromSuperview()
    }
    let (titleView, titleLabel, iconView) = SettingsViewFactory.makeTitleInfoView(
      title: viewModel.title)
    titleLabel.snp.remakeConstraints { make in
      make.top.bottom.equalToSuperview()
      make.leading.equalToSuperview().offset(Theme.current.sectionTitleMargin)
      make.trailing.equalToSuperview().offset(-(Theme.current.sectionTitleMargin + 16 + 4))
    }
    stackView.addArrangedSubview(titleView)
    if let detailView = detailView {
      stackView.removeArrangedSubview(detailView)
      detailView.removeFromSuperview()
    }
    if detailView == nil {
      let label = UILabel(frame: .zero)
      FontMetrics.default.scaleFont(Theme.current.sectionDescriptionFont, bindTo: label)
      label.textColor = Theme.current.sectionDescriptionColor
      label.lineBreakMode = .byWordWrapping
      label.numberOfLines = 0
      let detailView = UIView()
      detailView.addSubview(label)
      label.snp.makeConstraints { make in
        make.leading.trailing.equalToSuperview().inset(Theme.current.sectionTitleMargin)
        make.top.bottom.equalToSuperview()
      }
      self.detailLabel = label
      self.detailView = detailView
    }
    guard let detailLabel = detailLabel, let detailView = detailView else { return }
    stackView.addArrangedSubview(detailView)
    detailLabel.text = viewModel.detail
    let toolTipController = ToolTipAndDetailAppearanceController(
      titleView, detail: detailView,
      toolTip: viewModel.detail,
      lookUpKey: viewModel.lookUpKey, workspace: workspace, animateHidden: true)
    toolTipController.iconView = iconView
    self.toolTipController = toolTipController
    toolTipController.animateAlongIsHiddenChange = { _ in
      invalidateLayout()
    }
  }
}
