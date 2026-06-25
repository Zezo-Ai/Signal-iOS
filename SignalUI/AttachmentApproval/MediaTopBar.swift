//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

open class MediaTopBar: UIView {

    // Custom layout guide is necessary to allow to adjust the top margin.
    // Usually one could just change layoutMargins.top but that approach
    // sometimes doesn't work for this view because top inset gets overridden by UIKit
    // since `preservesSuperviewLayoutMargins` is set to `true`.
    public let controlsLayoutGuide = UILayoutGuide()

    override public init(frame: CGRect) {
        super.init(frame: frame)

        preservesSuperviewLayoutMargins = true
        translatesAutoresizingMaskIntoConstraints = false

        installConstraints()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installConstraints() {
        addLayoutGuide(controlsLayoutGuide)

        let otherLayoutGuide: UILayoutGuide = if #available(iOS 26, *) {
            // Avoids stoplight buttons in windowed mode on iPad.
            layoutGuide(for: .margins(cornerAdaptation: .vertical))
        } else {
            layoutMarginsGuide
        }

        NSLayoutConstraint.activate([
            // This first constraint is a crude but effective way of getting top margin same as side margin.
            // It works because `OWSTableViewController2.defaultHOuterMargin` is in most cases the size
            // of leading/trailing margin and `8` is the default top margin.
            controlsLayoutGuide.topAnchor.constraint(
                equalTo: otherLayoutGuide.topAnchor,
                constant: OWSTableViewController2.defaultHOuterMargin - 8,
            ),
            controlsLayoutGuide.leadingAnchor.constraint(
                equalTo: otherLayoutGuide.leadingAnchor,
            ),
            controlsLayoutGuide.trailingAnchor.constraint(
                equalTo: otherLayoutGuide.trailingAnchor,
            ),
            controlsLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public func install(in view: UIView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
