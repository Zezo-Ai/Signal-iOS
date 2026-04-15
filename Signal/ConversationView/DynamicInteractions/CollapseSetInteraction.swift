//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

class CollapseSetInteraction: TSInteraction {

    enum MessagesType: Equatable {
        case groupUpdates
        case chatUpdates
        case timerChanges
        case callEvents
    }

    let collapsedInteractions: [TSInteraction]

    let collapseSetType: MessagesType

    let isExpanded: Bool

    let finalTimerDescription: String?

    override var isDynamicInteraction: Bool { true }

    override var interactionType: OWSInteractionType { .collapseSet }

    override var shouldBeSaved: Bool { false }

    init(
        thread: TSThread,
        collapsedInteractions: [TSInteraction],
        collapseSetType: MessagesType,
        isExpanded: Bool = false,
    ) {
        owsPrecondition(!collapsedInteractions.isEmpty)
        self.collapsedInteractions = collapsedInteractions
        self.collapseSetType = collapseSetType
        self.isExpanded = isExpanded
        self.finalTimerDescription = Self.disappearingTimerDescription(
            for: collapsedInteractions,
            type: collapseSetType,
        )

        let firstInteraction = collapsedInteractions[0]
        super.init(
            customUniqueId: "CollapseSet_\(firstInteraction.timestamp)",
            timestamp: firstInteraction.timestamp,
            receivedAtTimestamp: firstInteraction.receivedAtTimestamp,
            thread: thread,
        )
    }

    private static func disappearingTimerDescription(
        for interactions: [TSInteraction],
        type: MessagesType,
    ) -> String? {
        guard
            type == .timerChanges,
            let last = interactions.last as? TSInfoMessage,
            let wrapper = last.infoMessageUserInfo?[.groupUpdateItems] as? TSInfoMessage.PersistableGroupUpdateItemsWrapper,
            let item = wrapper.updateItems.last
        else {
            return nil
        }

        switch item {
        case .disappearingMessagesEnabledByLocalUser(let durationMs),
             .disappearingMessagesEnabledByUnknownUser(let durationMs),
             .disappearingMessagesEnabledByOtherUser(_, let durationMs):
            return String.formatDurationLossless(durationSeconds: UInt32(durationMs / 1000))
        case .disappearingMessagesDisabledByLocalUser,
             .disappearingMessagesDisabledByOtherUser,
             .disappearingMessagesDisabledByUnknownUser:
            return OWSLocalizedString(
                "COLLAPSE_SET_TIMER_DISABLED",
                comment: "Short label shown in a collapsed timer-changes set indicating the timer is now disabled.",
            )
        default:
            return nil
        }
    }

    override func anyWillInsert(with transaction: DBWriteTransaction) {
        owsFailDebug("CollapseSetInteraction should not be saved to the database.")
    }
}
