//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient

public enum BackupExportJobStage: String, OWSSequentialProgressStep {
    /// Steps related to exporting the Backup file.
    case backupFileExport
    /// Steps related to uploading the Backup file.
    case backupFileUpload
    /// Steps related to uploading attachments to the media tier.
    case attachmentUpload
    /// Steps related to attachments, post-upload.
    case attachmentProcessing

    // Callers are only interested in the progress through a given stage, not
    // relative to other stages.
    public var progressUnitCount: UInt64 {
        switch self {
        case .backupFileExport: 1
        case .backupFileUpload: 1
        case .attachmentUpload: 1
        case .attachmentProcessing: 1
        }
    }
}

public enum BackupExportJobMode: CustomStringConvertible {
    case manual(OWSSequentialProgressRootSink<BackupExportJobStage>)
    case bgProcessingTask

    public var description: String {
        switch self {
        case .manual: "Manual"
        case .bgProcessingTask: "BGProcessingTask"
        }
    }
}

public enum BackupExportJobError: Error {
    case needsWifi
}

// MARK: -

/// Responsible for performing direct and ancillary steps to "export a Backup".
///
/// - Important
/// Callers should be careful about the possibility of running overlapping
/// Backup export jobs, and may prefer to call ``BackupExportJobRunner`` rather
/// than this type directly.
public protocol BackupExportJob {

    /// Export and upload a backup, then run all ancillary jobs
    /// (attachment upload, orphaning, and offloading).
    ///
    /// Cooperatively cancellable.
    func exportAndUploadBackup(
        mode: BackupExportJobMode,
    ) async throws
}

// MARK: -

class BackupExportJobImpl: BackupExportJob {
    private let accountKeyStore: AccountKeyStore
    private let backupArchiveManager: BackupArchiveManager
    private let backupAttachmentCoordinator: BackupAttachmentCoordinator
    private let backupAttachmentDownloadQueueStatusManager: BackupAttachmentDownloadQueueStatusManager
    private let backupAttachmentUploadProgress: BackupAttachmentUploadProgress
    private let backupAttachmentUploadQueueStatusManager: BackupAttachmentUploadQueueStatusManager
    private let backupSettingsStore: BackupSettingsStore
    private let db: DB
    private let logger: PrefixedLogger
    private let messageProcessor: MessageProcessor
    private let reachabilityManager: SSKReachabilityManager
    private let tsAccountManager: TSAccountManager

    init(
        accountKeyStore: AccountKeyStore,
        backupArchiveManager: BackupArchiveManager,
        backupAttachmentCoordinator: BackupAttachmentCoordinator,
        backupAttachmentDownloadQueueStatusManager: BackupAttachmentDownloadQueueStatusManager,
        backupAttachmentUploadProgress: BackupAttachmentUploadProgress,
        backupAttachmentUploadQueueStatusManager: BackupAttachmentUploadQueueStatusManager,
        backupSettingsStore: BackupSettingsStore,
        db: DB,
        messageProcessor: MessageProcessor,
        reachabilityManager: SSKReachabilityManager,
        tsAccountManager: TSAccountManager,
    ) {
        self.accountKeyStore = accountKeyStore
        self.backupArchiveManager = backupArchiveManager
        self.backupAttachmentCoordinator = backupAttachmentCoordinator
        self.backupAttachmentDownloadQueueStatusManager = backupAttachmentDownloadQueueStatusManager
        self.backupAttachmentUploadProgress = backupAttachmentUploadProgress
        self.backupAttachmentUploadQueueStatusManager = backupAttachmentUploadQueueStatusManager
        self.backupSettingsStore = backupSettingsStore
        self.db = db
        self.logger = PrefixedLogger(prefix: "[Backups][ExportJob]")
        self.messageProcessor = messageProcessor
        self.reachabilityManager = reachabilityManager
        self.tsAccountManager = tsAccountManager
    }

    func exportAndUploadBackup(
        mode: BackupExportJobMode,
    ) async throws {
        switch mode {
        case .manual:
            try await _exportAndUploadBackup(mode: mode)
        case .bgProcessingTask:
            await backupAttachmentDownloadQueueStatusManager.setIsMainAppAndActiveOverride(true)
            await backupAttachmentUploadQueueStatusManager.setIsMainAppAndActiveOverride(true)
            let result = await Result(
                catching: { () async throws -> Void in
                    try await _exportAndUploadBackup(mode: mode)
                },
            )
            await backupAttachmentDownloadQueueStatusManager.setIsMainAppAndActiveOverride(false)
            await backupAttachmentUploadQueueStatusManager.setIsMainAppAndActiveOverride(false)
            try result.get()
        }
    }

    private func _exportAndUploadBackup(
        mode: BackupExportJobMode,
    ) async throws {
        let localIdentifiers: LocalIdentifiers
        let backupKey: MessageRootBackupKey
        let aep: AccountEntropyPool
        let shouldAllowBackupUploadsOnCellular: Bool
        let hasConsumedMediaTierCapacity: Bool
        (
            localIdentifiers,
            backupKey,
            aep,
            shouldAllowBackupUploadsOnCellular,
            hasConsumedMediaTierCapacity,
        ) = try await db.awaitableWrite { tx throws in
            backupSettingsStore.setIsBackupUploadQueueSuspended(false, tx: tx)

            guard
                tsAccountManager.registrationState(tx: tx).isRegisteredPrimaryDevice,
                let aep = accountKeyStore.getAccountEntropyPool(tx: tx),
                let localIdentifiers = tsAccountManager.localIdentifiers(tx: tx)
            else {
                throw NotRegisteredError()
            }

            guard
                let backupKey = try? MessageRootBackupKey(
                    accountEntropyPool: aep,
                    aci: localIdentifiers.aci,
                )
            else {
                throw OWSAssertionError("Missing or invalid message root backup key.")
            }

            return (
                localIdentifiers,
                backupKey,
                aep,
                backupSettingsStore.shouldAllowBackupUploadsOnCellular(tx: tx),
                backupSettingsStore.hasConsumedMediaTierCapacity(tx: tx),
            )
        }

        let logger = self.logger.suffixed(with: "[\(mode)][\(aep.getLoggingKey())]")
        logger.info("Starting...")

        if !shouldAllowBackupUploadsOnCellular {
            // The job requires uploading the backup; if we're not on wifi
            // and therefore can't upload don't even bother generating the backup.
            if !reachabilityManager.isReachable(via: .wifi) {
                logger.info("Giving up; not connected to wifi & cellular uploads disabled")
                throw BackupExportJobError.needsWifi
            }
        }

        let progress: OWSSequentialProgressRootSink<BackupExportJobStage>?
        switch mode {
        case .manual(let _progress):
            progress = _progress
        case .bgProcessingTask:
            progress = nil
        }

        do {
            // Wait for message processing before creating a Backup, to maximize
            // the amount of message history we get into the Backup.
            logger.info("Waiting on message processing...")
            try? await messageProcessor.waitForFetchingAndProcessing()

            logger.info("Exporting backup...")
            let uploadMetadata = try await backupArchiveManager.exportEncryptedBackup(
                localIdentifiers: localIdentifiers,
                backupPurpose: .remoteExport(
                    key: backupKey,
                    chatAuth: .implicit(),
                ),
                progress: progress?.child(for: .backupFileExport),
            )

            logger.info("Uploading backup...")
            try await Retry.performWithBackoff(
                maxAttempts: 3,
                isRetryable: { error in
                    if error.isNetworkFailureOrTimeout || error.is5xxServiceResponse {
                        return true
                    }

                    guard let uploadError = error as? Upload.Error else {
                        return false
                    }

                    switch uploadError {
                    case
                        .networkError,
                        .networkTimeout,
                        .partialUpload,
                        .uploadFailure(recovery: .restart),
                        .uploadFailure(recovery: .resume):
                        return true
                    case .uploadFailure(recovery: .noMoreRetries):
                        return false
                    case .invalidUploadURL, .unsupportedEndpoint, .unexpectedResponseStatusCode, .missingFile, .unknown:
                        return false
                    }
                },
                block: {
                    _ = try await backupArchiveManager.uploadEncryptedBackup(
                        backupKey: backupKey,
                        metadata: uploadMetadata,
                        auth: .implicit(),
                        progress: progress?.child(for: .backupFileUpload),
                    )
                },
            )

            // Callers interested in detailed upload progress should use
            // BackupAttachmentUploadProgress or BackupAttachmentUploadTracker.
            try await performWithDummyProgress(progress?.child(for: .attachmentUpload)) {
                logger.info("Listing media...")
                try await Retry.performWithBackoff(
                    maxAttempts: 3,
                    isRetryable: { $0.isNetworkFailureOrTimeout || $0.is5xxServiceResponse },
                ) {
                    try await backupAttachmentCoordinator.queryListMediaIfNeeded()

                    if hasConsumedMediaTierCapacity {
                        // Run orphans now; include it in the list media progress for simplicity.
                        logger.info("Deleting orphaned attachments...")
                        try await backupAttachmentCoordinator.deleteOrphansIfNeeded()
                    }
                }

                logger.info("Uploading attachments...")
                let waitOnThumbnails = switch mode {
                case .bgProcessingTask: true
                case .manual: false
                }

                try await backupAttachmentCoordinator.backUpAllAttachments(waitOnThumbnails: waitOnThumbnails)
            }

            try await performWithDummyProgress(progress?.child(for: .attachmentProcessing)) {
                switch mode {
                case .manual:
                    break
                case .bgProcessingTask:
                    try? await backupAttachmentCoordinator.restoreAttachmentsIfNeeded()
                }

                if !hasConsumedMediaTierCapacity {
                    logger.info("Deleting orphaned attachments...")
                    try await backupAttachmentCoordinator.deleteOrphansIfNeeded()
                }

                logger.info("Offloading attachments...")
                try await backupAttachmentCoordinator.offloadAttachmentsIfNeeded()
            }

            logger.info("Done!")
        } catch let error as CancellationError {
            await db.awaitableWrite {
                switch mode {
                case .bgProcessingTask:
                    self.backupSettingsStore.incrementBackgroundBackupErrorCount(tx: $0)
                case .manual:
                    self.backupSettingsStore.setIsBackupUploadQueueSuspended(true, tx: $0)
                }
            }

            logger.warn("Canceled!")
            throw error
        } catch let error {
            await db.awaitableWrite {
                switch mode {
                case .bgProcessingTask:
                    self.backupSettingsStore.incrementBackgroundBackupErrorCount(tx: $0)
                case .manual:
                    self.backupSettingsStore.incrementInteractiveBackupErrorCount(tx: $0)
                }
            }

            logger.warn("Failed! \(error)")
            throw error
        }
    }

    /// Run the given block, which does not itself track progress, and complete
    /// the given "dummy" progress when the block is complete.
    private func performWithDummyProgress(
        _ progress: OWSProgressSink?,
        work: () async throws -> Void,
    ) async rethrows {
        try await work()

        if let progress {
            await progress
                .addSource(withLabel: "", unitCount: 1)
                .complete()
        }
    }
}
