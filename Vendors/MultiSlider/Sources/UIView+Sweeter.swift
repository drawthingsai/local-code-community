//
//  UIView+Sweeter.swift
//
//  Created by Yonat Sharon on 2019-02-08.
//

import UIKit

extension UIView {
  /// Sweeter: Set constant attribute. Example: `constrain(.width, to: 17)`
  @discardableResult func constrain(
    _ at: NSLayoutConstraint.Attribute,
    to: CGFloat = 0,
    ratio: CGFloat = 1,
    relation: NSLayoutConstraint.Relation = .equal,
    priority: UILayoutPriority = .required,
    identifier: String? = nil
  ) -> NSLayoutConstraint {
    let constraint = NSLayoutConstraint(
      item: self, attribute: at, relatedBy: relation,
      toItem: nil, attribute: .notAnAttribute, multiplier: ratio, constant: to
    )
    constraint.priority = priority
    constraint.identifier = identifier
    addConstraintWithoutConflict(constraint)
    return constraint
  }

  /// Sweeter: Pin subview at a specific place. Example: `constrain(label, at: .top)`
  @discardableResult func constrain(
    _ subview: UIView,
    at: NSLayoutConstraint.Attribute,
    diff: CGFloat = 0,
    ratio: CGFloat = 1,
    relation: NSLayoutConstraint.Relation = .equal,
    priority: UILayoutPriority = .required,
    identifier: String? = nil
  ) -> NSLayoutConstraint {
    let constraint = NSLayoutConstraint(
      item: subview, attribute: at, relatedBy: relation,
      toItem: self, attribute: at, multiplier: ratio, constant: diff
    )
    constraint.priority = priority
    constraint.identifier = identifier
    addConstraintWithoutConflict(constraint)
    return constraint
  }

  /// Sweeter: Pin two subviews to each other. Example:
  ///
  /// `constrain(label, at: .leading, to: textField)`
  ///
  /// `constrain(textField, at: .top, to: label, at: .bottom, diff: 8)`
  @discardableResult func constrain(
    _ subview: UIView,
    at: NSLayoutConstraint.Attribute,
    to subview2: UIView,
    at at2: NSLayoutConstraint.Attribute = .notAnAttribute,
    diff: CGFloat = 0,
    ratio: CGFloat = 1,
    relation: NSLayoutConstraint.Relation = .equal,
    priority: UILayoutPriority = .required,
    identifier: String? = nil
  ) -> NSLayoutConstraint {
    let at2real = at2 == .notAnAttribute ? at : at2
    let constraint = NSLayoutConstraint(
      item: subview, attribute: at, relatedBy: relation,
      toItem: subview2, attribute: at2real, multiplier: ratio, constant: diff
    )
    constraint.priority = priority
    constraint.identifier = identifier
    addConstraintWithoutConflict(constraint)
    return constraint
  }

  /// Sweeter: Add subview pinned to specific places. Example: `addConstrainedSubview(button, constrain: .centerX, .centerY)`
  @discardableResult func addConstrainedSubview(
    _ subview: UIView, constrain: NSLayoutConstraint.Attribute...
  ) -> [NSLayoutConstraint] {
    return addConstrainedSubview(subview, constrainedAttributes: constrain)
  }

  @discardableResult internal func addConstrainedSubview(
    _ subview: UIView, constrainedAttributes: [NSLayoutConstraint.Attribute]
  ) -> [NSLayoutConstraint] {
    subview.translatesAutoresizingMaskIntoConstraints = false
    addSubview(subview)
    return constrainedAttributes.map { self.constrain(subview, at: $0) }
  }

  internal func addConstraintWithoutConflict(_ constraint: NSLayoutConstraint) {
    removeConstraints(
      constraints.filter {
        constraint.firstItem === $0.firstItem
          && constraint.secondItem === $0.secondItem
          && constraint.firstAttribute == $0.firstAttribute
          && constraint.secondAttribute == $0.secondAttribute
      })
    addConstraint(constraint)
  }

  /// Sweeter: Search the view hierarchy recursively for a subview that conforms to `predicate`
  func viewInHierarchy(frontFirst: Bool = true, where predicate: (UIView) -> Bool) -> UIView? {
    if predicate(self) { return self }
    let views = frontFirst ? subviews.reversed() : subviews
    for subview in views {
      if let found = subview.viewInHierarchy(frontFirst: frontFirst, where: predicate) {
        return found
      }
    }
    return nil
  }

  /// Sweeter: Search the view hierarchy recursively for a subview with `aClass`
  func viewWithClass<T>(_ aClass: T.Type, frontFirst: Bool = true) -> T? {
    return viewInHierarchy(frontFirst: frontFirst, where: { $0 is T }) as? T
  }

  /// Sweeter: The color used to tint the view, as inherited from its superviews.
  var actualTintColor: UIColor {
    var tintedView: UIView? = self
    while let currentView = tintedView, nil == currentView.tintColor {
      tintedView = currentView.superview
    }
    return tintedView?.tintColor ?? UIColor(red: 0, green: 0.5, blue: 1, alpha: 1)  // swiftlint:disable:this no_magic_numbers
  }
}
