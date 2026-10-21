//
//  LabelDelegate.swift
//  Nantes
//
//  Created by Chris Hansen on 5/8/19.
//  Copyright © 2019 Instacart. All rights reserved.
//

import UIKit

public protocol NantesLabelDelegate: AnyObject {
  func attributedLabel(
    _ label: NantesLabel, didSelectAddress addressComponents: [NSTextCheckingKey: String])
  func attributedLabel(
    _ label: NantesLabel, didSelectDate date: Date, timeZone: TimeZone, duration: TimeInterval)
  func attributedLabel(_ label: NantesLabel, didSelectLink link: URL)
  func attributedLabel(_ label: NantesLabel, didSelectPhoneNumber phoneNumber: String)
  func attributedLabel(
    _ label: NantesLabel, didSelectTextCheckingResult result: NSTextCheckingResult)
  func attributedLabel(
    _ label: NantesLabel, didSelectTransitInfo transitInfo: [NSTextCheckingKey: String])
}

extension NantesLabelDelegate {
  public func attributedLabel(
    _ label: NantesLabel, didSelectAddress addressComponents: [NSTextCheckingKey: String]
  ) {}
  public func attributedLabel(
    _ label: NantesLabel, didSelectDate date: Date, timeZone: TimeZone, duration: TimeInterval
  ) {}
  public func attributedLabel(_ label: NantesLabel, didSelectLink link: URL) {}
  public func attributedLabel(_ label: NantesLabel, didSelectPhoneNumber phoneNumber: String) {}
  public func attributedLabel(
    _ label: NantesLabel, didSelectTextCheckingResult result: NSTextCheckingResult
  ) {}
  public func attributedLabel(
    _ label: NantesLabel, didSelectTransitInfo transitInfo: [NSTextCheckingKey: String]
  ) {}
}
