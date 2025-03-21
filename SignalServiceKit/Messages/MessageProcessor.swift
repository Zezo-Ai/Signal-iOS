//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import LibSignalClient

public class MessageProcessor {
    public static let messageProcessorDidDrainQueue = Notification.Name("messageProcessorDidDrainQueue")

    private var hasPendingEnvelopes: Bool {
        !pendingEnvelopes.isEmpty
    }

    /// When calling `waitForProcessingComplete` while message processing is
    /// suspended, there is a problem. We may have pending messages waiting to
    /// be processed once the suspension is lifted. But what's more, we may have
    /// started processing messages, then suspended, then called
    /// `waitForProcessingComplete` before that initial processing finished.
    /// Suspending does not interrupt processing if it already started.
    ///
    /// So there are 4 cases to worry about:
    /// 1. Message processing isn't suspended
    /// 2. Suspended with no pending messages
    /// 3. Suspended with pending messages and no active processing underway
    /// 4. Suspended but still processing from before the suspension took effect
    ///
    /// Cases 1 and 2 are easy and behave the same in all cases.
    ///
    /// Case 3 differs in behavior; sometimes we want to wait for suspension to
    /// be lifted and those pending messages to be processed, other times we
    /// don't want to wait to unsuspend.
    ///
    /// Case 4 is once again the same in all cases; processing has started and
    /// can't be stopped, so we should always wait until it finishes.
    public enum SuspensionBehavior {
        /// Default value. (Legacy behavior)
        /// If suspended with pending messages and no processing underway, wait for
        /// suspension to be lifted and those messages to be processed.
        case alwaysWait
        /// If suspended with pending messages, only wait if processing has already
        /// started. If it hasn't started, don't wait for it to start, so that the
        /// promise can resolve before suspension is lifted.
        case onlyWaitIfAlreadyInProgress
    }

    /// - parameter suspensionBehavior: What the promise should wait for if
    /// message processing is suspended; see `SuspensionBehavior` documentation
    /// for details.
    public func waitForProcessingComplete(
        suspensionBehavior: SuspensionBehavior = .alwaysWait
    ) -> Guarantee<Void> {
        guard CurrentAppContext().shouldProcessIncomingMessages else {
            return Guarantee.value(())
        }

        // Check if processing is suspended; if so we need to fork behavior.
        let shouldWaitForEverything: Bool
        if SSKEnvironment.shared.messagePipelineSupervisorRef.isMessageProcessingPermitted {
            shouldWaitForEverything = true
        } else {
            switch suspensionBehavior {
            case .alwaysWait:
                shouldWaitForEverything = true
            case .onlyWaitIfAlreadyInProgress:
                shouldWaitForEverything = false
            }
        }

        let shouldWaitForMessageProcessing: () -> Bool = {
            // Check if we are already processing, if so wait for that to finish.
            // If not don't wait even if we have pending messages; those won't process
            // until we unsuspend.
            return shouldWaitForEverything ? self.hasPendingEnvelopes : self.isDrainingPendingEnvelopes.get()
        }
        if shouldWaitForMessageProcessing() {
            let messageProcessingPromise = NotificationCenter.default.observe(once: Self.messageProcessorDidDrainQueue)
            // We must check (again) after setting up the observer in case we miss the
            // notification. If you check before setting up the observer, the
            // notification might fire while the thread is sleeping.
            if shouldWaitForMessageProcessing() {
                return messageProcessingPromise.then { _ in
                    // Recur, in case we've enqueued messages handled in another block.
                    self.waitForProcessingComplete(suspensionBehavior: suspensionBehavior)
                }.asVoid()
            }
        }

        let shouldWaitForGroupMessageProcessing: () -> Bool = {
            if shouldWaitForEverything {
                return SSKEnvironment.shared.databaseStorageRef.read {
                    SSKEnvironment.shared.groupsV2MessageProcessorRef.hasPendingJobs(tx: $0)
                }
            } else {
                return SSKEnvironment.shared.groupsV2MessageProcessorRef.isActivelyProcessing()
            }
        }
        if shouldWaitForGroupMessageProcessing() {
            let groupMessageProcessingPromise = NotificationCenter.default.observe(once: GroupsV2MessageProcessor.didFlushGroupsV2MessageQueue)
            if shouldWaitForGroupMessageProcessing() {
                return groupMessageProcessingPromise.then { _ in
                    // Recur, in case we've enqueued messages handled in another block.
                    self.waitForProcessingComplete(suspensionBehavior: suspensionBehavior)
                }.asVoid()
            }
        }

        return Guarantee.value(())
    }

    /// Suspends message processing, but before doing so processes any messages
    /// received so far.
    /// This suppression will persist until the suspension is explicitly lifted.
    /// For this reason calling this method is highly dangerous, please use with care.
    public func waitForProcessingCompleteAndThenSuspend(
        for suspension: MessagePipelineSupervisor.Suspension
    ) -> Guarantee<Void> {
        // We need to:
        // 1. wait to process
        // 2. suspend
        // 3. wait to process again
        // This is because steps 1 and 2 are not transactional, and in between a message
        // may get queued up for processing. After 2, nothing new can come in, so we only
        // need to wait the once.
        // In most cases nothing sneaks in between 1 and 2, so 3 resolves instantly.
        return waitForProcessingComplete(suspensionBehavior: .onlyWaitIfAlreadyInProgress).then(on: DispatchQueue.main) {
            SSKEnvironment.shared.messagePipelineSupervisorRef.suspendMessageProcessingWithoutHandle(for: suspension)
            return self.waitForProcessingComplete(suspensionBehavior: .onlyWaitIfAlreadyInProgress)
        }.recover(on: SyncScheduler()) { _ in return () }
    }

    public func waitForFetchingAndProcessing(
        suspensionBehavior: SuspensionBehavior = .alwaysWait
    ) -> Guarantee<Void> {
        SSKEnvironment.shared.messageFetcherJobRef.waitForFetchingComplete().then { () -> Guarantee<Void> in
            self.waitForProcessingComplete(suspensionBehavior: suspensionBehavior)
        }
    }

    private let appReadiness: AppReadiness

    public init(appReadiness: AppReadiness) {
        self.appReadiness = appReadiness

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )

        appReadiness.runNowOrWhenAppDidBecomeReadySync {
            SSKEnvironment.shared.messagePipelineSupervisorRef.register(pipelineStage: self)
        }
    }

    public func processReceivedEnvelopeData(
        _ envelopeData: Data,
        serverDeliveryTimestamp: UInt64,
        envelopeSource: EnvelopeSource,
        completion: @escaping (Error?) -> Void
    ) {
        guard !envelopeData.isEmpty else {
            completion(OWSAssertionError("Empty envelope, envelopeSource: \(envelopeSource)."))
            return
        }

        let protoEnvelope: SSKProtoEnvelope
        do {
            protoEnvelope = try SSKProtoEnvelope(serializedData: envelopeData)
        } catch {
            owsFailDebug("Failed to parse encrypted envelope \(error), envelopeSource: \(envelopeSource)")
            completion(error)
            return
        }

        // Drop any too-large messages on the floor. Well behaving clients should never send them.
        guard (protoEnvelope.content ?? Data()).count <= Self.maxEnvelopeByteCount else {
            completion(OWSAssertionError("Oversize envelope, envelopeSource: \(envelopeSource)."))
            return
        }

        processReceivedEnvelope(
            ReceivedEnvelope(
                envelope: protoEnvelope,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                completion: completion
            ),
            envelopeSource: envelopeSource
        )
    }

    public func processReceivedEnvelope(
        _ envelopeProto: SSKProtoEnvelope,
        serverDeliveryTimestamp: UInt64,
        envelopeSource: EnvelopeSource,
        completion: @escaping (Error?) -> Void
    ) {
        processReceivedEnvelope(
            ReceivedEnvelope(
                envelope: envelopeProto,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                completion: completion
            ),
            envelopeSource: envelopeSource
        )
    }

    private func processReceivedEnvelope(_ receivedEnvelope: ReceivedEnvelope, envelopeSource: EnvelopeSource) {
        let replacedEnvelope = pendingEnvelopes.enqueue(receivedEnvelope)
        if let replacedEnvelope {
            Logger.warn("Replaced \(replacedEnvelope.envelope.timestamp) serverGuid: \(replacedEnvelope.envelope.serverGuid as Optional)")
            replacedEnvelope.completion(MessageProcessingError.replacedEnvelope)
        }
        drainPendingEnvelopes()
    }

    private static let maxEnvelopeByteCount = 256 * 1024
    private let serialQueue = DispatchQueue(
        label: "org.signal.message-processor",
        autoreleaseFrequency: .workItem
    )

    private var pendingEnvelopes = PendingEnvelopes()

    private let isDrainingPendingEnvelopes = AtomicBool(false, lock: .init())

    private func drainPendingEnvelopes() {
        guard CurrentAppContext().shouldProcessIncomingMessages else { return }
        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else { return }

        guard SSKEnvironment.shared.messagePipelineSupervisorRef.isMessageProcessingPermitted else { return }

        serialQueue.async {
            self.isDrainingPendingEnvelopes.set(true)
            while autoreleasepool(invoking: { self.drainNextBatch() }) {}
            self.isDrainingPendingEnvelopes.set(false)
            if self.pendingEnvelopes.isEmpty {
                NotificationCenter.default.postNotificationNameAsync(Self.messageProcessorDidDrainQueue, object: nil)
            }
        }
    }

    /// Returns whether or not to continue draining the queue.
    private func drainNextBatch() -> Bool {
        assertOnQueue(serialQueue)

        guard SSKEnvironment.shared.messagePipelineSupervisorRef.isMessageProcessingPermitted else {
            return false
        }

        // We want a value that is just high enough to yield perf benefits.
        let kIncomingMessageBatchSize = 16
        // If the app is in the background, use batch size of 1.
        // This reduces the risk of us never being able to drain any
        // messages from the queue. We should fine tune this number
        // to yield the best perf we can get.
        let batchSize = CurrentAppContext().isInBackground() ? 1 : kIncomingMessageBatchSize
        let batch = pendingEnvelopes.nextBatch(batchSize: batchSize)
        let batchEnvelopes = batch.batchEnvelopes
        let pendingEnvelopesCount = batch.pendingEnvelopesCount

        guard !batchEnvelopes.isEmpty else {
            return false
        }

        let startTime = CACurrentMediaTime()

        var processedEnvelopesCount = 0
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            // This is only called via `drainPendingEnvelopes`, and that confirms that
            // we're registered. If we're registered, we must have `LocalIdentifiers`,
            // so this (generally) shouldn't fail.
            guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx) else {
                return
            }
            let localDeviceId = DependenciesBridge.shared.tsAccountManager.storedDeviceId(tx: tx)

            var remainingEnvelopes = batchEnvelopes
            while !remainingEnvelopes.isEmpty {
                guard SSKEnvironment.shared.messagePipelineSupervisorRef.isMessageProcessingPermitted else {
                    break
                }
                autoreleasepool {
                    // If we build a request, we must handle it to ensure it's not lost if we
                    // stop processing envelopes.
                    let combinedRequest = buildNextCombinedRequest(
                        envelopes: &remainingEnvelopes,
                        localIdentifiers: localIdentifiers,
                        localDeviceId: localDeviceId,
                        tx: tx
                    )
                    handle(
                        combinedRequest: combinedRequest,
                        localIdentifiers: localIdentifiers,
                        transaction: tx
                    )
                }
            }
            processedEnvelopesCount += batchEnvelopes.count - remainingEnvelopes.count
        }
        pendingEnvelopes.removeProcessedEnvelopes(processedEnvelopesCount)
        let endTime = CACurrentMediaTime()
        let formattedDuration = String(format: "%.1f", (endTime - startTime) * 1000)
        Logger.info("Processed \(processedEnvelopesCount) envelopes (of \(pendingEnvelopesCount) total) in \(formattedDuration)ms")
        return true
    }

    // If envelopes is not empty, this will emit a single request for a non-delivery receipt or one or more requests
    // all for delivery receipts.
    private func buildNextCombinedRequest(
        envelopes: inout [ReceivedEnvelope],
        localIdentifiers: LocalIdentifiers,
        localDeviceId: LocalDeviceId,
        tx: DBWriteTransaction
    ) -> RelatedProcessingRequests {
        let result = RelatedProcessingRequests()
        while let envelope = envelopes.first {
            envelopes.removeFirst()
            let request = processingRequest(
                for: envelope,
                localIdentifiers: localIdentifiers,
                localDeviceId: localDeviceId,
                tx: tx
            )
            result.add(request)
            if request.deliveryReceiptMessageTimestamps == nil {
                // If we hit a non-delivery receipt envelope, handle it immediately to avoid
                // keeping potentially large decrypted envelopes in memory.
                break
            }
        }
        return result
    }

    private func handle(combinedRequest: RelatedProcessingRequests, localIdentifiers: LocalIdentifiers, transaction: DBWriteTransaction) {
        // Efficiently handle delivery receipts for the same message by fetching the sent message only
        // once and only using one updateWith... to update the message with new recipient state.
        BatchingDeliveryReceiptContext.withDeferredUpdates(transaction: transaction) { context in
            for request in combinedRequest.processingRequests {
                handleProcessingRequest(request, context: context, localIdentifiers: localIdentifiers, tx: transaction)
            }
        }
    }

    private func reallyHandleProcessingRequest(
        _ request: ProcessingRequest,
        context: DeliveryReceiptContext,
        localIdentifiers: LocalIdentifiers,
        transaction: DBWriteTransaction
    ) -> Error? {
        switch request.state {
        case .completed(error: let error):
            Logger.info("Envelope completed early with error \(String(describing: error))")
            return error
        case .enqueueForGroup(let decryptedEnvelope, let envelopeData):
            SSKEnvironment.shared.groupsV2MessageProcessorRef.enqueue(
                envelopeData: envelopeData,
                plaintextData: decryptedEnvelope.plaintextData,
                wasReceivedByUD: decryptedEnvelope.wasReceivedByUD,
                serverDeliveryTimestamp: request.receivedEnvelope.serverDeliveryTimestamp,
                tx: transaction
            )
            SSKEnvironment.shared.messageReceiverRef.finishProcessingEnvelope(decryptedEnvelope, tx: transaction)
            return nil
        case .messageReceiverRequest(let messageReceiverRequest):
            SSKEnvironment.shared.messageReceiverRef.handleRequest(messageReceiverRequest, context: context, localIdentifiers: localIdentifiers, tx: transaction)
            SSKEnvironment.shared.messageReceiverRef.finishProcessingEnvelope(messageReceiverRequest.decryptedEnvelope, tx: transaction)
            return nil
        case .clearPlaceholdersOnly(let decryptedEnvelope):
            SSKEnvironment.shared.messageReceiverRef.finishProcessingEnvelope(decryptedEnvelope, tx: transaction)
            return nil
        case .serverReceipt(let serverReceiptEnvelope):
            SSKEnvironment.shared.messageReceiverRef.handleDeliveryReceipt(envelope: serverReceiptEnvelope, context: context, tx: transaction)
            return nil
        }
    }

    private func handleProcessingRequest(
        _ request: ProcessingRequest,
        context: DeliveryReceiptContext,
        localIdentifiers: LocalIdentifiers,
        tx: DBWriteTransaction
    ) {
        let error = reallyHandleProcessingRequest(request, context: context, localIdentifiers: localIdentifiers, transaction: tx)
        tx.addSyncCompletion { request.receivedEnvelope.completion(error) }
    }

    @objc
    private func registrationStateDidChange() {
        appReadiness.runNowOrWhenAppDidBecomeReadySync {
            self.drainPendingEnvelopes()
        }
    }

    public enum MessageAckBehavior {
        case shouldAck
        case shouldNotAck(error: Error)
    }

    public static func handleMessageProcessingOutcome(error: Error?) -> MessageAckBehavior {
        guard let error = error else {
            // Success.
            return .shouldAck
        }
        if case MessageProcessingError.replacedEnvelope = error {
            // _DO NOT_ ACK if de-duplicated before decryption.
            return .shouldNotAck(error: error)
        } else if case MessageProcessingError.blockedSender = error {
            return .shouldAck
        } else if let owsError = error as? OWSError,
                  owsError.errorCode == OWSErrorCode.failedToDecryptDuplicateMessage.rawValue {
            // _DO_ ACK if de-duplicated during decryption.
            return .shouldAck
        } else {
            Logger.warn("Failed to process message: \(error)")
            // This should only happen for malformed envelopes. We may eventually
            // want to show an error in this case.
            return .shouldAck
        }
    }
}

private struct ProcessingRequest {
    enum State {
        case completed(error: Error?)
        case enqueueForGroup(decryptedEnvelope: DecryptedIncomingEnvelope, envelopeData: Data)
        case messageReceiverRequest(MessageReceiverRequest)
        case serverReceipt(ServerReceiptEnvelope)
        // Message decrypted but had an invalid protobuf.
        case clearPlaceholdersOnly(DecryptedIncomingEnvelope)
    }

    let receivedEnvelope: ReceivedEnvelope
    let state: State

    // If this request is for a delivery receipt, return the timestamps for the sent-messages it
    // corresponds to.
    var deliveryReceiptMessageTimestamps: [UInt64]? {
        switch state {
        case .completed, .enqueueForGroup, .clearPlaceholdersOnly:
            return nil
        case .serverReceipt(let envelope):
            return [envelope.validatedEnvelope.timestamp]
        case .messageReceiverRequest(let request):
            guard
                case .receiptMessage = request.messageType,
                let receiptMessage = request.protoContent.receiptMessage,
                receiptMessage.type == .delivery
            else {
                return nil
            }
            return receiptMessage.timestamp
        }
    }

    init(_ receivedEnvelope: ReceivedEnvelope, state: State) {
        self.receivedEnvelope = receivedEnvelope
        self.state = state
    }
}

private class RelatedProcessingRequests {
    private(set) var processingRequests = [ProcessingRequest]()

    func add(_ processingRequest: ProcessingRequest) {
        processingRequests.append(processingRequest)
    }
}

private struct ProcessingRequestBuilder {
    let receivedEnvelope: ReceivedEnvelope
    let blockingManager: BlockingManager
    let localDeviceId: LocalDeviceId
    let localIdentifiers: LocalIdentifiers
    let messageDecrypter: OWSMessageDecrypter
    let messageReceiver: MessageReceiver

    init(
        _ receivedEnvelope: ReceivedEnvelope,
        blockingManager: BlockingManager,
        localDeviceId: LocalDeviceId,
        localIdentifiers: LocalIdentifiers,
        messageDecrypter: OWSMessageDecrypter,
        messageReceiver: MessageReceiver
    ) {
        self.receivedEnvelope = receivedEnvelope
        self.blockingManager = blockingManager
        self.localDeviceId = localDeviceId
        self.localIdentifiers = localIdentifiers
        self.messageDecrypter = messageDecrypter
        self.messageReceiver = messageReceiver
    }

    func build(tx: DBWriteTransaction) -> ProcessingRequest.State {
        do {
            let decryptionResult = try receivedEnvelope.decryptIfNeeded(
                messageDecrypter: messageDecrypter,
                localIdentifiers: localIdentifiers,
                localDeviceId: localDeviceId,
                tx: tx
            )
            switch decryptionResult {
            case .serverReceipt(let receiptEnvelope):
                return .serverReceipt(receiptEnvelope)
            case .decryptedMessage(let decryptedEnvelope):
                return processingRequest(for: decryptedEnvelope, tx: tx)
            }
        } catch {
            return .completed(error: error)
        }
    }

    private enum ProcessingStep {
        case discard
        case enqueueForGroupProcessing
        case processNow(shouldDiscardVisibleMessages: Bool)
    }

    private func processingStep(
        for decryptedEnvelope: DecryptedIncomingEnvelope,
        tx: DBWriteTransaction
    ) -> ProcessingStep {
        guard
            let contentProto = decryptedEnvelope.content,
            let groupContextV2 = GroupsV2MessageProcessor.groupContextV2(from: contentProto)
        else {
            // Non-v2-group messages can be processed immediately.
            return .processNow(shouldDiscardVisibleMessages: false)
        }

        guard GroupsV2MessageProcessor.canContextBeProcessedImmediately(
            groupContext: groupContextV2,
            tx: tx
        ) else {
            // Some v2 group messages required group state to be
            // updated before they can be processed.
            return .enqueueForGroupProcessing
        }
        let discardMode = GroupsMessageProcessor.discardMode(
            forMessageFrom: decryptedEnvelope.sourceAci,
            groupContext: groupContextV2,
            tx: tx
        )
        switch discardMode {
        case .discard:
            // Some v2 group messages should be discarded and not processed.
            return .discard
        case .doNotDiscard:
            return .processNow(shouldDiscardVisibleMessages: false)
        case .discardVisibleMessages:
            // Some v2 group messages should be processed, but discarding any "visible"
            // messages, e.g. text messages or calls.
            return .processNow(shouldDiscardVisibleMessages: true)
        }
    }

    private func processingRequest(
        for decryptedEnvelope: DecryptedIncomingEnvelope,
        tx: DBWriteTransaction
    ) -> ProcessingRequest.State {
        owsPrecondition(CurrentAppContext().shouldProcessIncomingMessages)

        // Pre-processing has to happen during the same transaction that performed
        // decryption.
        messageReceiver.preprocessEnvelope(decryptedEnvelope, tx: tx)

        // If the sender is in the block list, we can skip scheduling any additional processing.
        let sourceAddress = SignalServiceAddress(decryptedEnvelope.sourceAci)
        if blockingManager.isAddressBlocked(sourceAddress, transaction: tx) {
            Logger.info("Skipping processing for blocked envelope from \(decryptedEnvelope.sourceAci)")
            return .completed(error: MessageProcessingError.blockedSender)
        }

        if decryptedEnvelope.localIdentity == .pni {
            let identityManager = DependenciesBridge.shared.identityManager
            identityManager.setShouldSharePhoneNumber(with: decryptedEnvelope.sourceAci, tx: tx)
        }

        switch processingStep(for: decryptedEnvelope, tx: tx) {
        case .discard:
            // Do nothing.
            return .completed(error: nil)

        case .enqueueForGroupProcessing:
            // If we can't process the message immediately, we enqueue it for
            // for processing in the same transaction within which it was decrypted
            // to prevent data loss.
            let envelopeData: Data
            do {
                envelopeData = try decryptedEnvelope.envelope.serializedData()
            } catch {
                owsFailDebug("failed to reserialize envelope: \(error)")
                return .completed(error: error)
            }
            return .enqueueForGroup(decryptedEnvelope: decryptedEnvelope, envelopeData: envelopeData)

        case .processNow(let shouldDiscardVisibleMessages):
            // Envelopes can be processed immediately if they're:
            // 1. Not a GV2 message.
            // 2. A GV2 message that doesn't require updating the group.
            //
            // The advantage to processing the message immediately is that we can full
            // process the message in the same transaction that we used to decrypt it.
            // This results in a significant perf benefit verse queueing the message
            // and waiting for that queue to open new transactions and process
            // messages. The downside is that if we *fail* to process this message
            // (e.g. the app crashed or was killed), we'll have to re-decrypt again
            // before we process. This is safe since the decrypt operation would also
            // be rolled back (since the transaction didn't commit) and should be rare.
            messageReceiver.checkForUnknownLinkedDevice(in: decryptedEnvelope, tx: tx)

            let buildResult = MessageReceiverRequest.buildRequest(
                for: decryptedEnvelope,
                serverDeliveryTimestamp: receivedEnvelope.serverDeliveryTimestamp,
                shouldDiscardVisibleMessages: shouldDiscardVisibleMessages,
                tx: tx
            )

            switch buildResult {
            case .discard:
                return .completed(error: nil)
            case .noContent:
                return .clearPlaceholdersOnly(decryptedEnvelope)
            case .request(let messageReceiverRequest):
                return .messageReceiverRequest(messageReceiverRequest)
            }
        }
    }
}

private extension MessageProcessor {
    func processingRequest(
        for envelope: ReceivedEnvelope,
        localIdentifiers: LocalIdentifiers,
        localDeviceId: LocalDeviceId,
        tx: DBWriteTransaction
    ) -> ProcessingRequest {
        assertOnQueue(serialQueue)
        let builder = ProcessingRequestBuilder(
            envelope,
            blockingManager: SSKEnvironment.shared.blockingManagerRef,
            localDeviceId: localDeviceId,
            localIdentifiers: localIdentifiers,
            messageDecrypter: SSKEnvironment.shared.messageDecrypterRef,
            messageReceiver: SSKEnvironment.shared.messageReceiverRef
        )
        return ProcessingRequest(envelope, state: builder.build(tx: tx))
    }
}

// MARK: -

extension MessageProcessor: MessageProcessingPipelineStage {
    public func supervisorDidResumeMessageProcessing(_ supervisor: MessagePipelineSupervisor) {
        drainPendingEnvelopes()
    }
}

// MARK: -

private struct ReceivedEnvelope {
    let envelope: SSKProtoEnvelope
    let serverDeliveryTimestamp: UInt64
    let completion: (Error?) -> Void

    enum DecryptionResult {
        case serverReceipt(ServerReceiptEnvelope)
        case decryptedMessage(DecryptedIncomingEnvelope)
    }

    func decryptIfNeeded(
        messageDecrypter: OWSMessageDecrypter,
        localIdentifiers: LocalIdentifiers,
        localDeviceId: LocalDeviceId,
        tx: DBWriteTransaction
    ) throws -> DecryptionResult {
        // Figure out what type of envelope we're dealing with.
        let validatedEnvelope = try ValidatedIncomingEnvelope(envelope, localIdentifiers: localIdentifiers)

        switch validatedEnvelope.kind {
        case .serverReceipt:
            return .serverReceipt(try ServerReceiptEnvelope(validatedEnvelope))
        case .identifiedSender(let cipherType):
            return .decryptedMessage(
                try messageDecrypter.decryptIdentifiedEnvelope(
                    validatedEnvelope, cipherType: cipherType, localIdentifiers: localIdentifiers, tx: tx
                )
            )
        case .unidentifiedSender:
            return .decryptedMessage(
                try messageDecrypter.decryptUnidentifiedSenderEnvelope(
                    validatedEnvelope, localIdentifiers: localIdentifiers, localDeviceId: localDeviceId, tx: tx
                )
            )
        }
    }

    func isDuplicateOf(_ other: ReceivedEnvelope) -> Bool {
        guard let serverGuid = self.envelope.serverGuid else {
            owsFailDebug("Missing serverGuid.")
            return false
        }
        guard let otherServerGuid = other.envelope.serverGuid else {
            owsFailDebug("Missing other.serverGuid.")
            return false
        }
        return serverGuid == otherServerGuid
    }
}

// MARK: -

public enum EnvelopeSource {
    case unknown
    case websocketIdentified
    case websocketUnidentified
    case rest
    // We re-decrypt incoming messages after accepting a safety number change.
    case identityChangeError
    case debugUI
    case tests
}

// MARK: -

private class PendingEnvelopes {
    private let unfairLock = UnfairLock()
    private var pendingEnvelopes = [ReceivedEnvelope]()

    var isEmpty: Bool {
        unfairLock.withLock { pendingEnvelopes.isEmpty }
    }

    var count: Int {
        unfairLock.withLock { pendingEnvelopes.count }
    }

    struct Batch {
        let batchEnvelopes: [ReceivedEnvelope]
        let pendingEnvelopesCount: Int
    }

    func nextBatch(batchSize: Int) -> Batch {
        unfairLock.withLock {
            Batch(
                batchEnvelopes: Array(pendingEnvelopes.prefix(batchSize)),
                pendingEnvelopesCount: pendingEnvelopes.count
            )
        }
    }

    func removeProcessedEnvelopes(_ processedEnvelopesCount: Int) {
        unfairLock.withLock {
            pendingEnvelopes.removeFirst(processedEnvelopesCount)
        }
    }

    func enqueue(_ receivedEnvelope: ReceivedEnvelope) -> ReceivedEnvelope? {
        return unfairLock.withLock { () -> ReceivedEnvelope? in
            if let indexToReplace = pendingEnvelopes.firstIndex(where: { receivedEnvelope.isDuplicateOf($0) }) {
                let replacedEnvelope = pendingEnvelopes[indexToReplace]
                pendingEnvelopes[indexToReplace] = receivedEnvelope
                return replacedEnvelope
            } else {
                pendingEnvelopes.append(receivedEnvelope)
                return nil
            }
        }
    }
}

// MARK: -

public enum MessageProcessingError: Error {
    case wrongDestinationUuid
    case invalidMessageTypeForDestinationUuid
    case replacedEnvelope
    case blockedSender
}
