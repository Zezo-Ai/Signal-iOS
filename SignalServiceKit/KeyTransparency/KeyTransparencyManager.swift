//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
public import LibSignalClient

public final class KeyTransparencyManager {
    private static let logger = PrefixedLogger(prefix: "[KT]")
    private var logger: PrefixedLogger { Self.logger }

    private static let kvStore = NewKeyValueStore(collection: "KeyTransparencyManager")
    private var kvStore: NewKeyValueStore { Self.kvStore }

    /// Keys for `kvStore`.
    /// - Important
    /// If you're adding a new key here, consider whether it should be wiped
    /// when Key Transparency is disabled. See: `setIsEnabled`.
    private enum KVStoreKeys {
        /// Keys to a `Bool` representing whether or not KT is enabled.
        static let isEnabled = "isEnabled"
        /// Keys to a `SelfCheckState`'s raw value.
        static let selfCheckState = "selfCheckState"
        /// Keys to a `Bool` representing whether or not we should show
        /// first-time education about KT.
        static let shouldShowFirstTimeEducation = "shouldShowFirstTimeEducation"
        /// Keys to an opaque LibSignalClient blob.
        static let distinguishedTreeHead = "distinguishedTreeHead"
    }

    private let chatConnectionManager: ChatConnectionManager
    private let dateProvider: DateProvider
    private let db: DB
    private let identityManager: OWSIdentityManager
    private let localUsernameManager: LocalUsernameManager
    private let recipientDatabaseTable: RecipientDatabaseTable
    private let storageServiceManager: StorageServiceManager
    private let tsAccountManager: TSAccountManager
    private let udManager: OWSUDManager

    private let taskQueue: KeyedConcurrentTaskQueue<Aci>

    init(
        chatConnectionManager: ChatConnectionManager,
        dateProvider: @escaping DateProvider,
        db: DB,
        identityManager: OWSIdentityManager,
        localUsernameManager: LocalUsernameManager,
        recipientDatabaseTable: RecipientDatabaseTable,
        storageServiceManager: StorageServiceManager,
        tsAccountManager: TSAccountManager,
        udManager: OWSUDManager,
    ) {
        self.chatConnectionManager = chatConnectionManager
        self.dateProvider = dateProvider
        self.db = db
        self.identityManager = identityManager
        self.localUsernameManager = localUsernameManager
        self.recipientDatabaseTable = recipientDatabaseTable
        self.storageServiceManager = storageServiceManager
        self.tsAccountManager = tsAccountManager
        self.udManager = udManager

        self.taskQueue = KeyedConcurrentTaskQueue(concurrentLimitPerKey: 1)
    }

    // MARK: - Key Transparency Checks

    /// Parameters required to do a Key Transparency check.
    public struct CheckParams {
        fileprivate let aciInfo: KeyTransparency.AciInfo
        fileprivate let e164Info: KeyTransparency.E164Info?
        fileprivate let username: Username?
        fileprivate let localIdentifiers: LocalIdentifiers

        fileprivate var isLocalUser: Bool {
            localIdentifiers.contains(serviceId: aciInfo.aci)
        }
    }

    /// Prepare to perform a Key Transparency check for a contact.
    /// - Important
    /// Must not be called for the local user. See `prepareAndPerformSelfCheck`.
    /// - Returns
    /// Params required for the KT check, or `nil` if a check cannot be
    /// performed.
    public func prepareCheck(
        aci: Aci,
        localIdentifiers: LocalIdentifiers,
        tx: DBReadTransaction,
    ) -> CheckParams? {
        owsPrecondition(
            !localIdentifiers.contains(serviceId: aci),
            "External callers shouldn't be self-checking.",
        )

        let logger = logger.suffixed(with: "[\(aci)]")
        logger.info("")

        guard Self.isEnabled(tx: tx) else {
            logger.warn("Is opted out.")
            return nil
        }

        let aciInfo: KeyTransparency.AciInfo
        if let identityKey = try? identityManager.identityKey(for: aci, tx: tx) {
            aciInfo = KeyTransparency.AciInfo(
                aci: aci,
                identityKey: identityKey,
            )
        } else {
            logger.warn("Missing AciInfo.")
            return nil
        }

        let e164Info: KeyTransparency.E164Info
        if
            let recipient = recipientDatabaseTable.fetchRecipient(
                serviceId: aci,
                transaction: tx,
            ),
            let e164 = recipient.phoneNumber?.stringValue,
            let uak = udManager.udAccessKey(for: aci, tx: tx)
        {
            e164Info = KeyTransparency.E164Info(
                e164: e164,
                unidentifiedAccessKey: uak.keyData,
            )
        } else {
            logger.warn("Missing E164Info.")
            return nil
        }

        // We don't currently use the username when checking other users.
        let username: Username? = nil

        return CheckParams(
            aciInfo: aciInfo,
            e164Info: e164Info,
            username: username,
            localIdentifiers: localIdentifiers,
        )
    }

    /// Perform a Key Transparency check with the given validated parameters.
    ///
    /// Errors are retried internally. Throwing indicates a non-transient
    /// failure.
    public func performCheck(params: CheckParams) async throws {
        try await taskQueue.run(forKey: params.aciInfo.aci) {
            let logger = logger.suffixed(with: "[\(params.aciInfo.aci)]")

            do {
                // We want to retry network errors indefinitely, as we don't
                // want them to suggest that KT has failed.
                try await Retry.performWithBackoff(
                    maxAttempts: .max,
                    preferredBackoffBlock: { error -> TimeInterval? in
                        switch error {
                        case SignalError.rateLimitedError(let retryAfter, message: _):
                            return retryAfter
                        default:
                            return nil
                        }
                    },
                    isRetryable: { error -> Bool in
                        switch error {
                        case SignalError.rateLimitedError,
                             SignalError.connectionFailed,
                             SignalError.ioError,
                             SignalError.webSocketError:
                            return true
                        default:
                            return false
                        }
                    },
                    block: {
                        try await _performCheck(params: params, logger: logger)
                    },
                )

                logger.info("Success!")
            } catch {
                logger.warn("Failure! \(error)")
                throw error
            }
        }
    }

    private func _performCheck(
        params: CheckParams,
        logger: PrefixedLogger,
    ) async throws {
        let ktClient = try await chatConnectionManager.keyTransparencyClient()
        let libSignalStore = KeyTransparencyStoreForLibSignal(db: db)

        let existingKeyTransparencyBlob: Data?
        let selfCheckState: SelfCheckState?
        (
            existingKeyTransparencyBlob,
            selfCheckState,
        ) = db.read { tx in
            return (
                Self.getKeyTransparencyBlob(
                    aci: params.aciInfo.aci,
                    tx: tx,
                ),
                Self.selfCheckState(tx: tx),
            )
        }

        if params.isLocalUser {
            if existingKeyTransparencyBlob != nil {
                logger.info("Monitoring for self.")

                try await ktClient.monitor(
                    for: .`self`,
                    account: params.aciInfo,
                    e164: params.e164Info,
                    usernameHash: params.username?.hash,
                    store: libSignalStore,
                )
            } else {
                logger.info("Searching for self.")

                try await ktClient.search(
                    account: params.aciInfo,
                    e164: params.e164Info,
                    usernameHash: params.username?.hash,
                    store: libSignalStore,
                )
            }
        } else {
            // Require a self-check to succeed before checking others.
            switch selfCheckState {
            case nil:
                try await prepareAndPerformSelfCheck(localIdentifiers: params.localIdentifiers)
            case .succeeded:
                break
            case .failedOnce, .failedRepeatedly, .failedRepeatedlyAndWarned:
                throw OWSGenericError("Cannot check other with failed self-check.")
            }

            if existingKeyTransparencyBlob != nil {
                logger.info("Monitoring for other.")

                try await ktClient.monitor(
                    for: .other,
                    account: params.aciInfo,
                    e164: params.e164Info,
                    store: libSignalStore,
                )
            } else {
                logger.info("Searching for other.")

                try await ktClient.search(
                    account: params.aciInfo,
                    e164: params.e164Info,
                    store: libSignalStore,
                )
            }
        }
    }

    // MARK: - Self-check state

    private enum SelfCheckState: Int64 {
        case succeeded = 1
        case failedOnce = 2
        case failedRepeatedly = 3
        case failedRepeatedlyAndWarned = 4
    }

    private static func selfCheckState(tx: DBReadTransaction) -> SelfCheckState? {
        return kvStore.fetchValue(
            Int64.self,
            forKey: KVStoreKeys.selfCheckState,
            tx: tx,
        )
        .map { SelfCheckState(rawValue: $0)! }
    }

    private static func setSelfCheckState(_ state: SelfCheckState, tx: DBWriteTransaction) {
        kvStore.writeValue(state.rawValue, forKey: KVStoreKeys.selfCheckState, tx: tx)
    }

    public static func shouldWarnSelfCheckFailed(tx: DBReadTransaction) -> Bool {
        switch selfCheckState(tx: tx) {
        case .failedRepeatedly:
            return true
        case nil, .succeeded, .failedOnce, .failedRepeatedlyAndWarned:
            return false
        }
    }

    public static func setWarnedSelfCheckFailed(tx: DBWriteTransaction) {
        switch selfCheckState(tx: tx) {
        case .failedRepeatedly:
            Self.setSelfCheckState(.failedRepeatedlyAndWarned, tx: tx)
        case nil, .succeeded, .failedOnce, .failedRepeatedlyAndWarned:
            owsFailDebug("Unexpectedly setting warned, but shouldn't have warned?")
        }
    }

    // MARK: - Self-check

    private static let selfCheckCronStore = CronStore(uniqueKey: .keyTransparencySelfCheck)
    private static let selfCheckCronInterval: TimeInterval = if BuildFlags.KeyTransparency.conservativeSelfCheck {
        .day
    } else {
        .week
    }

    /// Use `Cron` to periodically perform a Key Transparency validation on the
    /// local user.
    public func registerSelfCheckForCron(cron: Cron) {
        cron.scheduleFrequently(
            mustBeRegistered: true,
            mustBeConnected: true,
            isRetryable: { _ in
                // This manager retries internally.
                return false
            },
            operation: { [self] () async throws -> Void in
                let mostRecentDate: Date
                let localIdentifiers: LocalIdentifiers?
                let isEnabled: Bool
                (
                    mostRecentDate,
                    localIdentifiers,
                    isEnabled,
                ) = db.read { tx in
                    return (
                        Self.selfCheckCronStore.mostRecentDate(tx: tx),
                        tsAccountManager.localIdentifiers(tx: tx),
                        Self.isEnabled(tx: tx),
                    )
                }

                guard
                    isEnabled,
                    let localIdentifiers,
                    dateProvider() > mostRecentDate.addingTimeInterval(Self.selfCheckCronInterval)
                else {
                    return
                }

                try await prepareAndPerformSelfCheck(localIdentifiers: localIdentifiers)
            },
            handleResult: { _ in
                // prepareAndPerformSelfCheck manages Cron state internally.
            },
        )
    }

#if USE_DEBUG_UI

    public func debugUI_prepareAndPerformSelfCheck() async throws {
        guard let localIdentifiers = tsAccountManager.localIdentifiersWithMaybeSneakyTransaction else {
            throw OWSAssertionError("Missing local identifiers!")
        }

        try await prepareAndPerformSelfCheck(localIdentifiers: localIdentifiers)
    }

    public func debugUI_setSelfCheckFailed() {
        db.write { tx in
            Self.setSelfCheckState(.failedRepeatedly, tx: tx)
        }
    }

#endif

    private func prepareSelfCheck(
        localIdentifiers: LocalIdentifiers,
        tx: DBReadTransaction,
    ) throws(OWSAssertionError) -> CheckParams {
        let logger = logger.suffixed(with: "[self]")
        logger.info("")

        let aciInfo: KeyTransparency.AciInfo
        if let localIdentityKey = identityManager.identityKeyPair(for: .aci, tx: tx) {
            aciInfo = KeyTransparency.AciInfo(
                aci: localIdentifiers.aci,
                identityKey: localIdentityKey.identityKeyPair.identityKey,
            )
        } else {
            throw OWSAssertionError("Missing AciInfo.", logger: logger)
        }

        let e164Info: KeyTransparency.E164Info?
        if let uak = udManager.udAccessKey(for: localIdentifiers.aci, tx: tx) {
            if tsAccountManager.phoneNumberDiscoverability(tx: tx).orDefault.isDiscoverable {
                e164Info = KeyTransparency.E164Info(
                    e164: localIdentifiers.phoneNumber,
                    unidentifiedAccessKey: uak.keyData,
                )
            } else {
                // If discoverability is disabled, we still want to do a
                // self-check but won't be able to self-check our E164.
                e164Info = nil
            }
        } else {
            throw OWSAssertionError("Missing E164Info.", logger: logger)
        }

        let username: Username?
        switch localUsernameManager.usernameState(tx: tx) {
        case .unset:
            username = nil
        case .available(let _username, _), .linkCorrupted(let _username):
            do {
                username = try Username(_username)
            } catch {
                throw OWSAssertionError("Failed to hash local username! \(error)", logger: logger)
            }
        case .usernameAndLinkCorrupted:
            throw OWSAssertionError("Local username is corrupted.", logger: logger)
        }

        return CheckParams(
            aciInfo: aciInfo,
            e164Info: e164Info,
            username: username,
            localIdentifiers: localIdentifiers,
        )
    }

    private func prepareAndPerformSelfCheck(
        localIdentifiers: LocalIdentifiers,
    ) async throws {
        do {
            let selfCheckParams = try db.read { tx in
                return try prepareSelfCheck(
                    localIdentifiers: localIdentifiers,
                    tx: tx,
                )
            }

            try await performCheck(params: selfCheckParams)

            await db.awaitableWrite { tx in
                logger.info("Self-check success.")
                Self.setSelfCheckState(.succeeded, tx: tx)

                Self.selfCheckCronStore.setMostRecentDate(
                    dateProvider(),
                    jitter: Self.selfCheckCronInterval / Cron.jitterFactor,
                    tx: tx,
                )
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            await db.awaitableWrite { tx in
                recordSelfCheckFailure(tx: tx)
            }
            throw error
        }
    }

    private func recordSelfCheckFailure(tx: DBWriteTransaction) {
        let intervalTillNextCron: TimeInterval
        let newSelfCheckState: SelfCheckState?

        switch Self.selfCheckState(tx: tx) {
        case nil, .succeeded:
            logger.warn("Self-check first failure.")
            newSelfCheckState = .failedOnce
            intervalTillNextCron = .day

            // A known failure mode is if a linked device changed something
            // KT-related (e.g., a username) and this device hasn't yet learned
            // about it. Kick off a storage service fetch, to try and make sure
            // we're up to date before our next attempt.
            tx.addSyncCompletion { [self] in
                storageServiceManager.restoreOrCreateManifestIfNecessary(
                    authedDevice: .implicit,
                    masterKeySource: .implicit,
                )
            }

        case .failedOnce:
            logger.warn("Self-check second failure.")
            newSelfCheckState = .failedRepeatedly
            intervalTillNextCron = Self.selfCheckCronInterval

        case .failedRepeatedly:
            logger.warn("Self-check continued failure.")
            newSelfCheckState = nil
            intervalTillNextCron = Self.selfCheckCronInterval

        case .failedRepeatedlyAndWarned:
            logger.warn("Self-check continued failure, already warned.")
            newSelfCheckState = if BuildFlags.KeyTransparency.conservativeSelfCheck {
                // Wipe the fact that we've already warned about these
                // continued failures, so we warn again.
                .failedRepeatedly
            } else {
                nil
            }
            intervalTillNextCron = Self.selfCheckCronInterval
        }

        if let newSelfCheckState {
            Self.setSelfCheckState(newSelfCheckState, tx: tx)
        }

        // Tell Cron we last completed in the past such that we'll try again
        // after the appropriate interval.
        Self.selfCheckCronStore.setMostRecentDate(
            dateProvider()
                .addingTimeInterval(-Self.selfCheckCronInterval)
                .addingTimeInterval(intervalTillNextCron),
            jitter: intervalTillNextCron / Cron.jitterFactor,
            tx: tx,
        )
    }

    // MARK: - Opt-out

    public static func isEnabled(tx: DBReadTransaction) -> Bool {
        guard BuildFlags.KeyTransparency.enabled else {
            return false
        }

        return kvStore.fetchValue(Bool.self, forKey: KVStoreKeys.isEnabled, tx: tx) ?? true
    }

    public static func setIsEnabled(_ isEnabled: Bool, tx: DBWriteTransaction) {
        logger.info("\(isEnabled)")

        kvStore.writeValue(isEnabled, forKey: KVStoreKeys.isEnabled, tx: tx)

        if !isEnabled {
            kvStore.removeValue(forKey: KVStoreKeys.distinguishedTreeHead, tx: tx)
            kvStore.removeValue(forKey: KVStoreKeys.selfCheckState, tx: tx)
            selfCheckCronStore.setMostRecentDate(.distantPast, jitter: 0, tx: tx)
            failIfThrows {
                try KeyTransparencyRecord.deleteAll(tx.database)
            }
        }
    }

    // MARK: - First-time education

    public static func shouldShowFirstTimeEducation(tx: DBReadTransaction) -> Bool {
        return kvStore.fetchValue(Bool.self, forKey: KVStoreKeys.shouldShowFirstTimeEducation, tx: tx) ?? true
    }

    public static func setHasShownFirstTimeEducation(_ value: Bool, tx: DBWriteTransaction) {
        kvStore.writeValue(value, forKey: KVStoreKeys.shouldShowFirstTimeEducation, tx: tx)
    }

    // MARK: -

    fileprivate static func getLastDistinguishedTreeHead(tx: DBReadTransaction) -> Data? {
        return kvStore.fetchValue(Data.self, forKey: KVStoreKeys.distinguishedTreeHead, tx: tx)
    }

    fileprivate static func setLastDistinguishedTreeHead(_ blob: Data, tx: DBWriteTransaction) {
        kvStore.writeValue(blob, forKey: KVStoreKeys.distinguishedTreeHead, tx: tx)
    }

    public static func getKeyTransparencyBlob(
        aci: Aci,
        tx: DBReadTransaction,
    ) -> Data? {
        return failIfThrows {
            try KeyTransparencyRecord.fetchOne(tx.database, key: aci.rawUUID)?.libsignalBlob
        }
    }

    public static func setKeyTransparencyBlob(
        _ libsignalBlob: Data,
        aci: Aci,
        tx: DBWriteTransaction,
    ) {
        failIfThrows {
            let record = KeyTransparencyRecord(
                aci: aci.rawUUID,
                libsignalBlob: libsignalBlob,
            )

            try record.insert(tx.database)
        }
    }
}

// MARK: - LibSignalClient.KeyTransparency.Store

/// An instance type conforming to `LibSignalClient.KeyTransparency.Store`, used
/// exclusively when calling LibSignal's KT APIs.
private struct KeyTransparencyStoreForLibSignal: KeyTransparency.Store {
    let db: DB

    func getLastDistinguishedTreeHead() async -> Data? {
        db.read { tx in
            KeyTransparencyManager.getLastDistinguishedTreeHead(tx: tx)
        }
    }

    func setLastDistinguishedTreeHead(to blob: Data) async {
        await db.awaitableWrite { tx in
            KeyTransparencyManager.setLastDistinguishedTreeHead(blob, tx: tx)
        }
    }

    func getAccountData(for aci: Aci) async -> Data? {
        db.read { tx in
            KeyTransparencyManager.getKeyTransparencyBlob(aci: aci, tx: tx)
        }
    }

    func setAccountData(_ data: Data, for aci: Aci) async {
        await db.awaitableWrite { tx in
            KeyTransparencyManager.setKeyTransparencyBlob(data, aci: aci, tx: tx)
        }
    }
}

// MARK: -

private struct KeyTransparencyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName: String = "KeyTransparency"

    // Overwrite if inserting a new record with an existing ACI primary key.
    static var persistenceConflictPolicy: PersistenceConflictPolicy {
        return PersistenceConflictPolicy(
            insert: .replace,
            update: .replace,
        )
    }

    let aci: UUID
    let libsignalBlob: Data

    enum CodingKeys: String, CodingKey {
        case aci
        case libsignalBlob
    }
}
