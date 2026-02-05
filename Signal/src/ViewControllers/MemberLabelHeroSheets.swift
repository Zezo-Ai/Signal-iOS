//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class MemberLabelAboutOverrideHeroSheet: HeroSheetViewController {
    init(dontShowAgainHandler: @escaping () -> Void) {
        super.init(
            hero: .image(.tag22, tintColor: UIColor.Signal.label),
            title: OWSLocalizedString(
                "MEMBER_LABEL_HERO_SHEET_ABOUT_OVERRIDE_TITLE",
                comment: "Title for a sheet shown if a user will show their member label over their About message in a group.",
            ),
            body: OWSLocalizedString(
                "MEMBER_LABEL_HERO_SHEET_ABOUT_OVERRIDE_BODY",
                comment: "Body for a sheet shown if a user will show their member label over their About message in a group.",
            ),
            primaryButton: HeroSheetViewController.Button(
                title: CommonStrings.okButton,
                action: .dismiss,
            ),
            secondaryButton: HeroSheetViewController.Button(
                title: CommonStrings.dontShowAgainButton,
                style: .secondary,
                action: .custom({ sheet in
                    sheet.dismiss(animated: true)
                    dontShowAgainHandler()
                }),
            ),
        )
    }
}
