//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

class BadgeThanksSheetPresenter {
    private enum Deps {
        static var donationReceiptCredentialResultStore: DonationReceiptCredentialResultStore {
            DependenciesBridge.shared.donationReceiptCredentialResultStore
        }
    }

    private let badgeStore: BadgeStore
    private let db: DB
    private let donationReceiptCredentialResultStore: DonationReceiptCredentialResultStore

    private var redemptionSuccess: DonationReceiptCredentialRedemptionSuccess
    private let successMode: DonationReceiptCredentialResultStore.Mode

    private init(
        badgeStore: BadgeStore,
        db: DB,
        donationReceiptCredentialResultStore: DonationReceiptCredentialResultStore,
        redemptionSuccess: DonationReceiptCredentialRedemptionSuccess,
        successMode: DonationReceiptCredentialResultStore.Mode,
    ) {
        self.badgeStore = badgeStore
        self.db = db
        self.donationReceiptCredentialResultStore = donationReceiptCredentialResultStore
        self.redemptionSuccess = redemptionSuccess
        self.successMode = successMode
    }

    static func fromGlobalsWithSneakyTransaction(
        successMode: DonationReceiptCredentialResultStore.Mode,
    ) -> BadgeThanksSheetPresenter? {
        guard
            let redemptionSuccess = SSKEnvironment.shared.databaseStorageRef.read(block: { tx in
                Deps.donationReceiptCredentialResultStore.getRedemptionSuccess(
                    successMode: successMode,
                    tx: tx,
                )
            })
        else {
            owsFailBeta("[Donations] Missing redemption success while trying to present badge thanks! \(successMode)")
            return nil
        }

        return .fromGlobals(
            redemptionSuccess: redemptionSuccess,
            successMode: successMode,
        )
    }

    static func fromGlobals(
        redemptionSuccess: DonationReceiptCredentialRedemptionSuccess,
        successMode: DonationReceiptCredentialResultStore.Mode,
    ) -> BadgeThanksSheetPresenter {
        return BadgeThanksSheetPresenter(
            badgeStore: SSKEnvironment.shared.profileManagerRef.badgeStore,
            db: DependenciesBridge.shared.db,
            donationReceiptCredentialResultStore: Deps.donationReceiptCredentialResultStore,
            redemptionSuccess: redemptionSuccess,
            successMode: successMode,
        )
    }

    @MainActor
    func presentAndRecordBadgeThanks(
        fromViewController: UIViewController,
    ) async {
        let logger = PrefixedLogger(prefix: "[Donations]", suffix: "\(successMode)")
        logger.info("Preparing to present badge thanks sheet.")

        let badge: ProfileBadge
        do {
            guard
                let _badge = db.read(block: { tx in
                    badgeStore.fetchBadgeWithId(redemptionSuccess.badgeID, tx: tx)
                })
            else {
                throw OWSAssertionError("Missing badge for expected badge ID! \(redemptionSuccess.badgeID)")
            }

            badge = _badge
            try await self.badgeStore.populateAssetsOnBadge(badge)
        } catch {
            logger.error("Failed to populate badge assets for badge thanks sheet! \(error)")
            return
        }

        logger.info("Showing badge thanks sheet on receipt credential redemption.")
        let badgeThanksSheet = BadgeThanksSheet(
            receiptCredentialRedemptionSuccess: redemptionSuccess,
            newBadge: badge,
        )

        await fromViewController.awaitablePresent(badgeThanksSheet, animated: true)

        await db.awaitableWrite { tx in
            donationReceiptCredentialResultStore.setHasPresentedSuccess(
                successMode: self.successMode,
                tx: tx,
            )
        }
    }
}
