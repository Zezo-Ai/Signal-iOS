//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

class BackupRecordAndConfirmKeyCoordinator {
    enum Option {
        case showConfirmKeyButton(onConfirmed: () -> Void)
        case showCreateNewKeyButton(onPressed: (BackupRecordKeyViewController) -> Void)
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
        aepMode: BackupRecordKeyViewController.AEPMode,
        options: [Option],
    ) {
        guard let navigationController else {
            return
        }

        let recordKeyViewController = BackupRecordKeyViewController(
            aepMode: aepMode,
            bottomButtonConfigs: options.compactMap { option in
                switch option {
                case .showConfirmKeyButton(let onConfirmed):
                    return BackupRecordKeyViewController.BottomButtonConfig(
                        titleText: CommonStrings.continueButton,
                        style: .primary,
                    ) { [self] _ in
                        showConfirmKey(
                            aep: aepMode.aep,
                            onConfirmed: onConfirmed,
                        )
                    }
                case .showCreateNewKeyButton(let onPressed):
                    return BackupRecordKeyViewController.BottomButtonConfig(
                        titleText: OWSLocalizedString(
                            "BACKUP_RECORD_KEY_CREATE_NEW_KEY_BUTTON_TITLE",
                            comment: "Title for a button allowing users to create a new 'Recovery Key'.",
                        ),
                        style: .secondary,
                        action: { recordKeyViewController in
                            onPressed(recordKeyViewController)
                        },
                    )
                }
            },
        )

        navigationController.pushViewController(recordKeyViewController, animated: true)
    }

    private func showConfirmKey(
        aep: AccountEntropyPool,
        onConfirmed: @escaping () -> Void,
    ) {
        guard let navigationController else {
            return
        }

        owsAssertDebug(
            navigationController.topViewController is BackupRecordKeyViewController,
            "Unexpected topViewController! \(type(of: navigationController.topViewController))",
        )

        let confirmKeyViewController = BackupConfirmKeyViewController(
            aep: aep,
            onConfirmed: { _ in
                onConfirmed()
            },
            onSeeKeyAgain: {
                navigationController.popViewController(animated: true)
            },
        )

        navigationController.pushViewController(confirmKeyViewController, animated: true)
    }
}
