//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

class ImageEditorTopBar: MediaTopBar {

    let undoButton = UIButton(
        configuration: .roundMedia(image: UIImage(imageLiteralResourceName: "undo-28"), size: 44),
    )

    var isUndoButtonHidden: Bool {
        get { undoButton.alpha == 0 }
        set { undoButton.alpha = newValue ? 0 : 1 }
    }

    let clearAllButton = UIButton(configuration: .capsuleMedia(
        title: OWSLocalizedString(
            "MEDIA_EDITOR_BUTTON_CLEAR",
            comment: "Title for the button that discards all edits in media editor.",
        ),
        buttonHeight: 44,
    ))
    var isClearAllButtonHidden: Bool {
        get { clearAllButton.alpha == 0 }
        set { clearAllButton.alpha = newValue ? 0 : 1 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        let stackView = UIStackView(arrangedSubviews: [undoButton, UIView.hStretchingSpacer(), clearAllButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.alignment = .center
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: controlsLayoutGuide.leadingAnchor),
            stackView.topAnchor.constraint(equalTo: controlsLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: controlsLayoutGuide.bottomAnchor),
            stackView.trailingAnchor.constraint(equalTo: controlsLayoutGuide.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

protocol ImageEditorBottomBarButtonProvider: AnyObject {

    var middleButtons: [UIButton] { get }
}

protocol ImageEditorBottomBarProvider: AnyObject {

    func bottomBar(for viewController: UIViewController) -> ImageEditorBottomBar
}

class ImageEditorBottomBar: UIView {

    let cancelButton: UIButton = RoundMediaButton(
        image: UIImage(imageLiteralResourceName: "x-28"),
        backgroundStyle: .solid(RoundMediaButton.defaultBackgroundColor),
    )
    let doneButton: UIButton = RoundMediaButton(
        image: UIImage(imageLiteralResourceName: "check-28"),
        backgroundStyle: .solid(RoundMediaButton.defaultBackgroundColor),
    )

    let buttons: [UIButton]

    let stackView = UIStackView()

    private var areControlsHidden = false
    private var stackViewPositionConstraint: NSLayoutConstraint?

    init(buttonProvider: ImageEditorBottomBarButtonProvider?) {
        let middleButtons = buttonProvider?.middleButtons ?? []
        self.buttons = [cancelButton] + middleButtons + [doneButton]

        super.init(frame: .zero)

        preservesSuperviewLayoutMargins = true
        setContentHuggingVerticalHigh()

        // Constrain bottom edge to bottom safe area.
        if UIDevice.current.hasIPhoneXNotch {
            layoutMargins.bottom = 0
        }

        buttons.forEach { button in
            button.setContentHuggingHigh()
            button.setCompressionResistanceVerticalHigh()
        }

        let middleStackView = UIStackView(arrangedSubviews: middleButtons)
        middleStackView.spacing = 2
        stackView.addArrangedSubviews([cancelButton, middleStackView, doneButton])
        stackView.distribution = .equalSpacing
        stackView.isOpaque = false
        addSubview(stackView)
        stackView.autoPinLeadingToSuperviewMargin(withInset: -cancelButton.layoutMargins.leading)
        stackView.autoPinTrailingToSuperviewMargin(withInset: -doneButton.layoutMargins.trailing)
        stackView.heightAnchor.constraint(equalTo: layoutMarginsGuide.heightAnchor).isActive = true
        setControls(hidden: false)
    }

    @available(*, unavailable, message: "Use init(buttonProvider:)")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setControls(hidden: Bool) {
        guard hidden != areControlsHidden || stackViewPositionConstraint == nil else { return }

        if let stackViewPositionConstraint {
            removeConstraint(stackViewPositionConstraint)
            self.stackViewPositionConstraint = nil
        }

        let stackViewPositionConstraint: NSLayoutConstraint
        if hidden {
            stackViewPositionConstraint = stackView.topAnchor.constraint(equalTo: bottomAnchor)
        } else {
            stackViewPositionConstraint = stackView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor)
        }
        addConstraint(stackViewPositionConstraint)
        self.stackViewPositionConstraint = stackViewPositionConstraint

        areControlsHidden = hidden
    }
}
