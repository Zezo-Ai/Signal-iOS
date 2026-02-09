//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

protocol MemberLabelViewControllerPresenter: UIViewController {
    func reloadMemberLabelIfNeeded()
}

public final class MemberLabelCoordinator {
    weak var presenter: MemberLabelViewControllerPresenter?

    var groupModel: TSGroupModelV2
    private var memberLabel: MemberLabel?
    private let kvStore: NewKeyValueStore
    private let groupNameColors: GroupNameColors

    private enum KVStoreKeys {
        static let ignoreMemberLabelAboutOverrideKey = "ignoreMemberLabelAboutOverrideKeyV2"
    }

    init(groupModel: TSGroupModelV2, groupNameColors: GroupNameColors) {
        self.groupModel = groupModel
        self.memberLabel = groupModel.groupMembership.localUserMemberLabel
        self.groupNameColors = groupNameColors
        self.kvStore = NewKeyValueStore(collection: "MemberLabelCoordinator")
    }

    func updateWithNewGroupModel(_ newGroupModel: TSGroupModelV2, tx: DBReadTransaction) {
        guard let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci else {
            return
        }

        self.groupModel = newGroupModel
        self.memberLabel = newGroupModel.groupMembership.memberLabel(for: localAci)
    }

    func present() {
        let memberLabelViewController = MemberLabelViewController(
            memberLabel: memberLabel?.label,
            emoji: memberLabel?.labelEmoji,
            groupNameColors: groupNameColors,
        )
        memberLabelViewController.updateDelegate = self

        presenter?.present(OWSNavigationController(rootViewController: memberLabelViewController), animated: true)
    }

    private func showOverrideAboutWarningIfNeeded(localUserBio: String?) {
        let db = DependenciesBridge.shared.db
        let ignoreMemberLabelAboutOverrideKey = db.read { tx in
            let value = self.kvStore.fetchValue(
                Bool.self,
                forKey: KVStoreKeys.ignoreMemberLabelAboutOverrideKey,
                tx: tx,
            )
            return value == true
        }

        if localUserBio != nil, !ignoreMemberLabelAboutOverrideKey {
            let hero = MemberLabelAboutOverrideHeroSheet(
                dontShowAgainHandler: {
                    db.write { tx in
                        self.kvStore.writeValue(
                            true,
                            forKey: KVStoreKeys.ignoreMemberLabelAboutOverrideKey,
                            tx: tx,
                        )
                    }
                },
            )
            presenter?.present(hero, animated: true)
        }
    }

    private func showMemberLabelSaveFailed() {
        OWSActionSheets.showActionSheet(
            title: OWSLocalizedString(
                "MEMBER_LABEL_FAIL_TO_SAVE",
                comment: "Error indicating member label could not save.",
            ),
            message: OWSLocalizedString(
                "CHECK_YOUR_CONNECTION_TRY_AGAIN_WARNING",
                comment: "Message indicating a user should check connection and try again.",
            ),
        )
    }

    func updateLabelForLocalUser(memberLabel: MemberLabel?) {
        guard let presenter else { return }
        let changeLabelBlock: () -> Void = {
            Task { @MainActor in
                let db = DependenciesBridge.shared.db
                let tsAccountManager = DependenciesBridge.shared.tsAccountManager
                let profileManager = SSKEnvironment.shared.profileManagerRef

                guard
                    let localUserInfo = db.read(block: { tx -> (Aci, String?)? in
                        guard let localAci = tsAccountManager.localIdentifiers(tx: tx)?.aci else {
                            return nil
                        }
                        return (localAci, profileManager.userProfile(for: SignalServiceAddress(localAci), tx: tx)?.bioForDisplay)
                    })
                else {
                    owsFailDebug("Missing local aci")
                    self.showMemberLabelSaveFailed()
                    return
                }

                do {
                    try await ModalActivityIndicatorViewController.presentAndPropagateResult(from: presenter, wrappedAsyncBlock: {

                        let localAci = localUserInfo.0
                        try await GroupManager.changeMemberLabel(
                            groupModel: self.groupModel,
                            aci: localAci,
                            label: memberLabel,
                        )
                    })

                    presenter.reloadMemberLabelIfNeeded()

                    if memberLabel != nil {
                        self.showOverrideAboutWarningIfNeeded(localUserBio: localUserInfo.1)
                    }
                } catch {
                    self.showMemberLabelSaveFailed()
                }
            }
        }

        if let p = presenter.presentedViewController {
            p.dismiss(animated: true, completion: {
                changeLabelBlock()
            })
            return
        }
        changeLabelBlock()
    }
}
