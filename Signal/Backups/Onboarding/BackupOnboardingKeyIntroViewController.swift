//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import SwiftUI

class BackupOnboardingKeyIntroViewController: HostingContainer<BackupOnboardingKeyIntroView> {
    private let viewModel: BackupsOnboardingKeyIntroViewModel

    private let onBackPressed: (BackupOnboardingKeyIntroViewController) -> Void
    private let _onContinue: (BackupOnboardingKeyIntroViewController) -> Void

    init(
        onBackPressed: @escaping (BackupOnboardingKeyIntroViewController) -> Void,
        onContinue: @escaping (BackupOnboardingKeyIntroViewController) -> Void,
    ) {
        self.viewModel = BackupsOnboardingKeyIntroViewModel()

        self.onBackPressed = onBackPressed
        self._onContinue = onContinue

        super.init(wrappedView: BackupOnboardingKeyIntroView(viewModel: viewModel))

        viewModel.actionsDelegate = self
        OWSTableViewController2.removeBackButtonText(viewController: self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = .init(
            image: UIImage(named: "chevron-left-bold-28"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                onBackPressed(self)
            },
        )

        isModalInPresentation = true
    }

    // MARK: - OWSNavigationChildController

    override var shouldCancelNavigationBack: Bool {
        true
    }
}

// MARK: -

extension BackupOnboardingKeyIntroViewController: BackupsOnboardingKeyIntroViewModel.ActionsDelegate {
    fileprivate func onContinue() {
        _onContinue(self)
    }
}

// MARK: -

private class BackupsOnboardingKeyIntroViewModel {
    protocol ActionsDelegate: AnyObject {
        func onContinue()
    }

    weak var actionsDelegate: ActionsDelegate?

    func onContinue() {
        actionsDelegate?.onContinue()
    }
}

struct BackupOnboardingKeyIntroView: View {
    private struct BulletPoint: Identifiable {
        let image: UIImage
        let text: String

        var id: String { text }
    }

    fileprivate let viewModel: BackupsOnboardingKeyIntroViewModel

    private let bulletPoints: [BulletPoint] = [
        BulletPoint(
            image: .number,
            text: OWSLocalizedString(
                "BACKUP_ONBOARDING_KEY_INTRO_BULLET_1",
                comment: "Text for a bullet point in a view introducing the 'Recovery Key' during an onboarding flow.",
            ),
        ),
        BulletPoint(
            image: .lock,
            text: OWSLocalizedString(
                "BACKUP_ONBOARDING_KEY_INTRO_BULLET_2",
                comment: "Text for a bullet point in a view introducing the 'Recovery Key' during an onboarding flow.",
            ),
        ),
        BulletPoint(
            image: .errorCircle,
            text: OWSLocalizedString(
                "BACKUP_ONBOARDING_KEY_INTRO_BULLET_3",
                comment: "Text for a bullet point in a view introducing the 'Recovery Key' during an onboarding flow.",
            ),
        ),
    ]

    var body: some View {
        ScrollableContentPinnedFooterView {
            VStack {
                Spacer().frame(height: 20)

                Image(.backupsKey)
                    .frame(width: 80, height: 80)

                Spacer().frame(height: 16)

                Text(OWSLocalizedString(
                    "BACKUP_ONBOARDING_KEY_INTRO_TITLE",
                    comment: "Title for a view introducing the 'Recovery Key' during an onboarding flow.",
                ))
                .font(.title)
                .fontWeight(.semibold)
                .foregroundStyle(Color.Signal.label)

                Spacer().frame(height: 32)

                VStack(alignment: .leading, spacing: 24) {
                    ForEach(bulletPoints) { bulletPoint in
                        HStack(alignment: .top, spacing: 12) {
                            Image(uiImage: bulletPoint.image)
                                .frame(width: 24, height: 24)

                            Text(bulletPoint.text)
                        }
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Color.Signal.label)
                    }
                }
            }
            .padding(.horizontal)
        } pinnedFooter: {
            Button {
                viewModel.onContinue()
            } label: {
                Text(OWSLocalizedString(
                    "BACKUP_ONBOARDING_KEY_INTRO_CONTINUE_BUTTON_TITLE",
                    comment: "Title for a continue button for a view introducing the 'Recovery Key' during an onboarding flow.",
                ))
            }
            .buttonStyle(Registration.UI.LargePrimaryButtonStyle())
            .padding(.horizontal, 24)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal)
        .background(Color.Signal.groupedBackground)
    }
}

// MARK: -

#if DEBUG

extension BackupsOnboardingKeyIntroViewModel {
    static func forPreview() -> BackupsOnboardingKeyIntroViewModel {
        class PreviewActionsDelegate: ActionsDelegate {
            func onContinue() { print("Continuing...!") }
        }

        let viewModel = BackupsOnboardingKeyIntroViewModel()
        let actionsDelegate = PreviewActionsDelegate()
        viewModel.actionsDelegate = actionsDelegate
        ObjectRetainer.retainObject(actionsDelegate, forLifetimeOf: viewModel)

        return viewModel
    }
}

#Preview {
    BackupOnboardingKeyIntroView(viewModel: .forPreview())
}

#endif
