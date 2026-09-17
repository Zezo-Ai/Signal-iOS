//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

class LocalFileBackupOnboardingIntroViewController: OWSViewController {
    private let onContinue: (UIViewController) -> Void

    init(onContinue: @escaping (UIViewController) -> Void) {
        self.onContinue = onContinue
        super.init()
        OWSTableViewController2.removeBackButtonText(viewController: self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.groupedBackground

        let logo = UIImageView(image: UIImage(named: "backups-on-device"))
        logo.contentMode = .scaleAspectFit
        logo.isAccessibilityElement = false

        let titleLabel = UILabel.titleLabelForRegistration(
            text: OWSLocalizedString(
                "LOCAL_FILE_BACKUP_ONBOARDING_INTRO_TITLE",
                comment: "Title for a view introducing local file backups during the onboarding flow.",
            ),
        )

        let explanationLabel = UILabel.explanationLabelForRegistration(
            text: OWSLocalizedString(
                "LOCAL_FILE_BACKUP_ONBOARDING_INTRO_SUBTITLE",
                comment: "Subtitle for a view introducing local file backups during the onboarding flow.",
            ),
        )

        let bulletsStack = UIStackView(arrangedSubviews: [
            buildBulletView(
                image: UIImage(resource: .lock),
                text: OWSLocalizedString(
                    "LOCAL_FILE_BACKUP_ONBOARDING_INTRO_BULLET_1",
                    comment: "Bullet point on a view introducing local file backups during onboarding flow.",
                ),
            ),
            buildBulletView(
                image: UIImage(resource: .checkSquare),
                text: OWSLocalizedString(
                    "LOCAL_FILE_BACKUP_ONBOARDING_INTRO_BULLET_2",
                    comment: "Bullet point on a view introducing local file backups during onboarding flow.",
                ),
            ),
            buildBulletView(
                image: UIImage(resource: .trash),
                text: OWSLocalizedString(
                    "LOCAL_FILE_BACKUP_ONBOARDING_INTRO_BULLET_3",
                    comment: "Bullet point on a view introducing local file backups during onboarding flow.",
                ),
            ),
        ])
        bulletsStack.isLayoutMarginsRelativeArrangement = true
        bulletsStack.directionalLayoutMargins = .init(hMargin: 32, vMargin: 0)
        bulletsStack.axis = .vertical
        bulletsStack.spacing = 26

        let continueButton = UIButton(
            configuration: .largePrimary(title: CommonStrings.continueButton),
            primaryAction: UIAction { [weak self] _ in self?.didTapContinue() },
        )

        let stackView = addStaticContentStackView(
            arrangedSubviews: [
                logo,
                titleLabel,
                explanationLabel,
                bulletsStack,
                .vStretchingSpacer(),
                continueButton.enclosedInVerticalStackView(isFullWidthButton: true),
            ],
            isScrollable: true,
        )
        stackView.spacing = 24
        stackView.setCustomSpacing(36, after: explanationLabel)
    }

    // MARK: -

    private func buildBulletView(image: UIImage, text: String) -> UIView {
        let imageView = UIImageView(image: image.withRenderingMode(.alwaysTemplate))
        imageView.tintColor = .Signal.label
        imageView.autoSetDimensions(to: .square(24))

        let label = UILabel()
        label.text = text
        label.font = .dynamicTypeBodyClamped
        label.textColor = .Signal.label
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [imageView, label])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center

        return row
    }

    private func didTapContinue() {
        onContinue(self)
    }
}

// MARK: -

#if DEBUG

@available(iOS 17, *)
#Preview {
    return UINavigationController(
        rootViewController: LocalFileBackupOnboardingIntroViewController { _ in },
    )
}

#endif
