//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

#if USE_DEBUG_UI

final class DebugUIKeyTransparency: DebugUIPage {
    let name = "Key Transparency"

    func section(thread: TSThread?) -> OWSTableSection? {
        let keyTransparencyManager = DependenciesBridge.shared.keyTransparencyManager

        let items: [OWSTableItem] = [
            OWSTableItem(title: "Pretend self-check failed", actionBlock: {
                keyTransparencyManager.debugUI_setSelfCheckFailed()
            }),
            OWSTableItem(title: "Perform self-check", actionBlock: {
                guard let frontmostVC = CurrentAppContext().frontmostViewController() else {
                    return
                }

                Task { @MainActor in
                    do {
                        try await keyTransparencyManager.debugUI_performSelfCheck()
                        frontmostVC.presentToast(text: "Self-check succeeded!")
                    } catch {
                        frontmostVC.presentToast(text: "Self-check failed!")
                    }
                }
            }),
        ]

        return OWSTableSection(items: items)
    }
}

#endif
