//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

class BackupSaveAndConfirmKeyCoordinator {
    enum Option {
        case showConfirmKey(onConfirmed: () -> Void)
        case showCreateNewKey(onPressed: (BackupSaveKeyViewController) -> Void)
    }

    private weak var navigationController: UINavigationController?

    init(
        navigationController: UINavigationController,
    ) {
        self.navigationController = navigationController
    }

    deinit {
        Logger.verbose("")
    }

    func present(
        aepMode: BackupSaveKeyViewController.AEPMode,
        options: [Option],
    ) {
        guard let navigationController else {
            return
        }

        let saveKeyViewController = BackupSaveKeyViewController(
            aepMode: aepMode,
            bottomButtonConfigs: options.compactMap { option in
                switch option {
                case .showConfirmKey(let onConfirmed):
                    return BackupSaveKeyViewController.BottomButtonConfig(
                        titleText: CommonStrings.continueButton,
                        style: .primary,
                    ) { [self] _ in
                        showConfirmKey(
                            aep: aepMode.aep,
                            onConfirmed: onConfirmed,
                        )
                    }
                case .showCreateNewKey(let onPressed):
                    return BackupSaveKeyViewController.BottomButtonConfig(
                        titleText: OWSLocalizedString(
                            "BACKUP_RECORD_KEY_CREATE_NEW_KEY_BUTTON_TITLE",
                            comment: "Title for a button allowing users to create a new 'Recovery Key'.",
                        ),
                        style: .secondary,
                        action: { saveKeyViewController in
                            onPressed(saveKeyViewController)
                        },
                    )
                }
            },
        )

        navigationController.pushViewController(saveKeyViewController, animated: true)
    }

    private func showConfirmKey(
        aep: AccountEntropyPool,
        onConfirmed: @escaping () -> Void,
    ) {
        guard let navigationController else {
            return
        }

        owsAssertDebug(
            navigationController.topViewController is BackupSaveKeyViewController,
            "Unexpected topViewController! \(type(of: navigationController.topViewController))",
        )

        let confirmKeyViewController = BackupConfirmKeyViewController(
            aep: aep,
            onConfirmed: { _ in
                onConfirmed()
            },
            onSeeKeyAgain: { [weak navigationController] in
                navigationController?.popViewController(animated: true)
            },
        )

        navigationController.pushViewController(confirmKeyViewController, animated: true)
    }
}
