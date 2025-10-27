//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public class OutgoingPollVoteMessage: TSOutgoingMessage {
    @objc
    var targetPollTimestamp: UInt64 = 0

    @objc
    var targetPollAuthorAciBinary: Data?

    @objc
    var voteOptionIndexes: [UInt32]?

    @objc
    var voteCount: UInt32 = 0

    public init(
        thread: TSGroupThread,
        targetPollTimestamp: UInt64,
        targetPollAuthorAci: Aci,
        voteOptionIndexes: [UInt32],
        voteCount: UInt32,
        tx: DBReadTransaction
    ) {
        self.targetPollTimestamp = targetPollTimestamp
        self.targetPollAuthorAciBinary = targetPollAuthorAci.serviceIdBinary
        self.voteOptionIndexes = voteOptionIndexes
        self.voteCount = voteCount

        super.init(
            outgoingMessageWith: .withDefaultValues(thread: thread),
            additionalRecipients: [],
            explicitRecipients: [],
            skippedRecipients: [],
            transaction: tx
        )
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    required public init(dictionary dictionaryValue: [String: Any]!) throws {
        try super.init(dictionary: dictionaryValue)
    }

    override public var shouldBeSaved: Bool { false }

    override var contentHint: SealedSenderContentHint { .implicit }

    override public func dataMessageBuilder(
        with thread: TSThread,
        transaction: DBReadTransaction
    ) -> SSKProtoDataMessageBuilder? {
        guard let dataMessageBuilder = super.dataMessageBuilder(
            with: thread,
            transaction: transaction
        ) else {
            return nil
        }

        let pollVoteBuilder = SSKProtoDataMessagePollVote.builder()

        pollVoteBuilder.setTargetSentTimestamp(targetPollTimestamp)

        if let targetPollAuthorAciBinary {
            pollVoteBuilder.setTargetAuthorAciBinary(targetPollAuthorAciBinary)
        }

        if let voteOptionIndexes {
            pollVoteBuilder.setOptionIndexes(voteOptionIndexes)
        }

        pollVoteBuilder.setVoteCount(voteCount)

        dataMessageBuilder.setPollVote(
            pollVoteBuilder.buildInfallibly()
        )

        if !BuildFlags.pollKeepProtoVersion {
            dataMessageBuilder.setRequiredProtocolVersion(UInt32(SSKProtoDataMessageProtocolVersion.polls.rawValue))
        }

        return dataMessageBuilder
    }

    public override func updateWithSendSuccess(tx: DBWriteTransaction) {
        guard let targetPollAuthorAciBinary, let voteOptionIndexes else {
            owsFailDebug("Missing required fields in poll vote message")
            return
        }

        do {
            try DependenciesBridge.shared.pollMessageManager.processPollVoteMessageDidSend(
                targetPollTimestamp: targetPollTimestamp,
                targetPollAuthorAci: Aci.parseFrom(serviceIdBinary: targetPollAuthorAciBinary),
                optionIndexes: voteOptionIndexes,
                voteCount: voteCount,
                tx: tx
            )
        } catch {
            Logger.error("Failed to update vote message as sent: \(error)")
        }
    }

    public override func updateWithAllSendingRecipientsMarkedAsFailed(
        error: (any Error)? = nil,
        transaction tx: DBWriteTransaction
    ) {
        super.updateWithAllSendingRecipientsMarkedAsFailed(error: error, transaction: tx)

        revertLocalStateIfFailedForEveryone(tx: tx)
    }

    private func revertLocalStateIfFailedForEveryone(tx: DBWriteTransaction) {
        // Do nothing if we successfully delivered to anyone. Only cleanup
        // local state if we fail to deliver to anyone.
        guard sentRecipientAddresses().isEmpty else {
            Logger.warn("Failed to send poll vote to some recipients")
            return
        }

        guard let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci,
              let localRecipientId = DependenciesBridge.shared.recipientDatabaseTable.fetchRecipient(
            serviceId: localAci,
            transaction: tx
        )?.id else {
            owsFailDebug("Missing local aci or recipient")
            return
        }

        Logger.error("Failed to send vote to all recipients.")

        do {
            guard let targetPollAuthorAciBinary else {
                owsFailDebug("Can't parse author aci")
                return
            }

            let targetPollAuthorAci = try Aci.parseFrom(serviceIdBinary: targetPollAuthorAciBinary)

            guard let targetMessage = try DependenciesBridge.shared.interactionStore.fetchMessage(
                timestamp: targetPollTimestamp,
                incomingMessageAuthor: targetPollAuthorAci == localAci ? nil : targetPollAuthorAci,
                transaction: tx
            ),
                  let interactionId = targetMessage.grdbId?.int64Value
            else {
                Logger.error("Can't find target poll")
                return
            }

            try PollStore().revertVoteCount(
                voteCount: Int32(voteCount),
                interactionId: interactionId,
                voteAuthorId: localRecipientId,
                transaction: tx
            )

            SSKEnvironment.shared.databaseStorageRef.touch(interaction: targetMessage, shouldReindex: false, tx: tx)
        } catch {
            Logger.error("Failed to revert vote count: \(error)")
        }
    }
}
