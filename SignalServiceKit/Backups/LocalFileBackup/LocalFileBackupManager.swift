//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import GRDB
import LibSignalClient

/// Manager to handle local file backup logic, including file I/O, UIDocumentPicker logic, and security-scoped bookmark handling.
/// Actual archiving of the backup is handled by BackupArchiveManager.
public class LocalFileBackupManager: NSObject, UIDocumentPickerDelegate {
    public enum FileStructure: String {
        case rootDirectory = "SignalBackups"
        case attachmentDirectory = "files"
        case backupFile = "main"
        case metadataFile = "metadata"

        static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            return formatter
        }()

        static func backupDirectory(date: Date) -> String {
            return "signal-backups-\(dateFormatter.string(from: date))"
        }
    }

    struct AttachmentWithMetadata {
        let attachment: Attachment
        let metadata: BackupLocalFileAttachmentMetadataRecord
    }

    private let logger: PrefixedLogger
    private let db: DB
    private let kvStore: NewKeyValueStore
    private let dateProvider: DateProvider
    private let attachmentStore: AttachmentStore

    private enum StoreKeys {
        static let bookmarkDataKey = "bookmarkData"
        static let lastEnumeratedAttachmentIdKey = "lastEnumeratedAttachmentId"
    }

    public init(
        db: DB,
        dateProvider: @escaping DateProvider,
        attachmentStore: AttachmentStore,
    ) {
        self.db = db
        self.dateProvider = dateProvider
        self.attachmentStore = attachmentStore
        self.logger = PrefixedLogger(prefix: "[LocalFileBackups]")
        self.kvStore = NewKeyValueStore(collection: "LocalFileBackups")
    }

    /*
     ---- DIRECTORY STRUCTURE ----

     SignalBackups/
     ├─ signal-backup-{year}-{month}-{day}-{hr}-{min}-{sec}/
          ├─ metadata
          ├─ main
          └─ files
     └─ files/
       └─ <fileName prefix>
          └─ <fileName 1>
       └─ <fileName prefix>
          ├─ <fileName 2>
          └─ <fileName 3>
       ...
       └─ <fileName prefix>
          └─ <fileName N>
     */

    // MARK: - Archiving

    /// - Parameter backupsRootDirectory
    /// The SignalBackups directory.
    private func existingFilesInBackupDirectory(backupsRootDirectory: URL) throws -> [String: Int] {
        let fileCoordinator = NSFileCoordinator()

        var existingFiles: [String: Int] = [:]
        try fileCoordinator.coordinateThrows(
            readingItemAt: backupsRootDirectory,
            options: .withoutChanges,
            by: { temporaryFileUrl in
                let filesDirectoryUrl = temporaryFileUrl.appendingPathComponent(FileStructure.attachmentDirectory.rawValue)
                guard
                    let enumerator = FileManager.default.enumerator(
                        at: filesDirectoryUrl,
                        includingPropertiesForKeys: [.fileSizeKey, .nameKey],
                        options: [],
                    )
                else {
                    return
                }
                while let fileURL = enumerator.nextObject() as? URL {
                    let fileValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .nameKey, .isDirectoryKey])
                    if let isDir = fileValues.isDirectory, isDir {
                        continue
                    }
                    if
                        let size = fileValues.fileSize,
                        let name = fileValues.name
                    {
                        existingFiles[name] = size
                    } else {
                        owsFailDebug("Unexpectedly missing size/name from resource keys!")
                    }
                }
            },
        )
        return existingFiles
    }

    /// - Parameter backupsRootDirectory
    /// The SignalBackups directory.
    func writeQueuedAttachmentsToDisk(backupsRootDirectory: URL, currentBackupDirectoryName: String) throws {
        let fileCoordinator = NSFileCoordinator()

        let existingFiles = try existingFilesInBackupDirectory(backupsRootDirectory: backupsRootDirectory)

        let attachmentBatchSize = 50
        while true {
            let (attachmentsWithMetadata, localFileExports) = db.read { tx in
                failIfThrows {
                    let localFileExports = try BackupLocalFileAttachmentExportRecord
                        .limit(attachmentBatchSize)
                        .fetchAll(tx.database)

                    let ids = localFileExports.map({ $0.attachmentRowId })
                    let attachments = attachmentStore.fetch(ids: ids, tx: tx)
                    let attachmentsWithMetadata: [AttachmentWithMetadata] = try attachments.compactMap {
                        let metadata = try BackupLocalFileAttachmentMetadataRecord.filter(key: $0.id).fetchOne(tx.database)
                        guard let metadata else {
                            // TODO: Store error to present to beta user
                            owsFailBeta("Local file backup attachment in the export queue is missing metadata")
                            return nil
                        }
                        return AttachmentWithMetadata(attachment: $0, metadata: metadata)
                    }

                    return (attachmentsWithMetadata, localFileExports)
                }
            }
            if localFileExports.isEmpty { break }

            let attachmentMetadataFile = backupsRootDirectory
                .appendingPathComponent(currentBackupDirectoryName)
                .appendingPathComponent(FileStructure.attachmentDirectory.rawValue)

            guard let outputStream = OutputStream(url: attachmentMetadataFile, append: false) else {
                throw OWSAssertionError("Unable to initalize output stream")
            }
            outputStream.open()

            let manifestStream = TransformingOutputStream(
                transforms: [ChunkedOutputStreamTransform()],
                outputStream: outputStream,
            )

            for attachmentWithMetadata in attachmentsWithMetadata {
                guard let attachmentStream = attachmentWithMetadata.attachment.asStream() else {
                    continue
                }

                let localKey = attachmentWithMetadata.metadata.localKey
                let localFileBackupMediaName = mediaNameForAttachment(
                    localKey: localKey,
                    plaintextHash: attachmentStream.plaintextHash,
                )

                if let _ = existingFiles[localFileBackupMediaName] {
                    // Already exists on disk, can skip copying.
                    // TODO: [KC] also check encrypted byte count is what we expect
                    continue
                }

                let encryptedFileHandle = try Cryptography.encryptedAttachmentFileHandle(
                    at: attachmentStream.fileURL,
                    plaintextLength: UInt64(safeCast: attachmentStream.unencryptedByteCount),
                    attachmentKey: AttachmentKey(combinedKey: attachmentStream.attachment.encryptionKey),
                )

                let attachmentKey = try AttachmentKey(combinedKey: localKey)

                // The files dir is divided into subdirectories based on the first 2 characters of the media name
                let attachmentSubDirectory = backupsRootDirectory
                    .appendingPathComponent(FileStructure.attachmentDirectory.rawValue)
                    .appendingPathComponent(String(localFileBackupMediaName.prefix(2)))

                try fileCoordinator.coordinateThrows(
                    writingItemAt: attachmentSubDirectory,
                    options: [],
                    writingItemAt: attachmentMetadataFile,
                    options: [],
                ) { attachmentDirUrl, metadataURL in
                    try FileManager.default.createDirectory(at: attachmentDirUrl, withIntermediateDirectories: true)
                    let destination = attachmentDirUrl.appendingPathComponent(localFileBackupMediaName)

                    let _ = try Cryptography.reencryptFileHandle(
                        at: encryptedFileHandle,
                        attachmentKey: attachmentKey,
                        encryptedOutputUrl: destination,
                        applyExtraPadding: true,
                    )

                    var fileProto = LocalBackupProto_FilesFrame()
                    fileProto.item = .mediaName(localFileBackupMediaName)
                    try manifestStream.write(data: fileProto.serializedData())
                }
            }

            try manifestStream.close()

            failIfThrows {
                try db.write { tx in
                    for localFileExport in localFileExports {
                        try localFileExport.delete(tx.database)
                    }
                }
            }
        }
    }

    func mediaNameForAttachment(localKey: Data, plaintextHash: Data) -> String {
        let value = plaintextHash + localKey
        var sha = SHA256()
        sha.update(data: value)
        let hash = Data(sha.finalize())
        return hash.hexadecimalString
    }

    func queueLocalBackupAttachmentsForExport(localFileBackupAttachmentCollector: LocalFileBackupAttachmentCollector) async throws(CancellationError) {
        try await TimeGatedBatch.processAll(
            db: db,
            processBatch: { tx throws(CancellationError) in
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard let attachmentId = localFileBackupAttachmentCollector.removeLast() else {
                    return .done(())
                }
                let attachmentToExport = BackupLocalFileAttachmentExportRecord(attachmentRowId: attachmentId)
                failIfThrows {
                    try attachmentToExport.insert(tx.database)
                }
                return .more
            },
        )
    }

    private func buildMetadataProto(messageRootBackupKey: MessageRootBackupKey) throws -> LocalBackupProto_Metadata {
        let localBackupMetadataKey = messageRootBackupKey.backupKey.deriveLocalBackupMetadataKey()
        let backupIdBytes = messageRootBackupKey.backupId
        let iv = Randomness.generateRandomBytes(12)
        let nonce = iv + Data(count: 4) // Last 4 bytes are 0 for the counter.
        var encryptedBackupId = backupIdBytes
        try Aes256Ctr32.process(&encryptedBackupId, key: localBackupMetadataKey, nonce: nonce)

        var metadataProto = LocalBackupProto_Metadata()
        metadataProto.version = 1

        var encryptedBackupIdProto = LocalBackupProto_Metadata.EncryptedBackupId()
        encryptedBackupIdProto.iv = iv
        encryptedBackupIdProto.encryptedID = encryptedBackupId

        metadataProto.backupID = encryptedBackupIdProto

        return metadataProto
    }

    func ensureAttachmentMetadataExists() async {
        struct TxContextAttachmentMetadata {
            var cursor: FailIfThrowsRecordCursor<Attachment.Record>
            var lastEnumeratedAttachmentId: Attachment.IDType?
            var didFinish: Bool
        }
        await TimeGatedBatch.processAll(
            db: db,
            buildTxContext: { tx -> TxContextAttachmentMetadata in
                let lastEnumeratedAttachmentId: Attachment.IDType? = kvStore.fetchValue(Int64.self, forKey: StoreKeys.lastEnumeratedAttachmentIdKey, tx: tx)

                return TxContextAttachmentMetadata(
                    cursor: FailIfThrowsRecordCursor {
                        var query = Attachment.Record
                            .filter(Column(Attachment.Record.CodingKeys.plaintextHash) != nil)
                            .order(Column(Attachment.Record.CodingKeys.sqliteId))

                        if let lastEnumeratedAttachmentId {
                            query = query
                                .filter(Column(Attachment.Record.CodingKeys.sqliteId) > lastEnumeratedAttachmentId)
                        }
                        return try query.fetchCursor(tx.database)
                    },
                    lastEnumeratedAttachmentId: lastEnumeratedAttachmentId,
                    didFinish: false,
                )
            },
            processBatch: { tx, txContext -> TimeGatedBatch.ProcessBatchResult<Void> in
                guard let nextAttachmentRecord = txContext.cursor.next() else {
                    txContext.didFinish = true
                    return .done(())
                }

                let attachmentRecordId = nextAttachmentRecord.sqliteId!
                txContext.lastEnumeratedAttachmentId = attachmentRecordId

                guard let unencryptedByteCount = nextAttachmentRecord.unencryptedByteCount else {
                    return .more
                }

                let existingMetadata = failIfThrows {
                    try BackupLocalFileAttachmentMetadataRecord
                        .filter(key: attachmentRecordId)
                        .fetchOne(tx.database)
                }

                if existingMetadata == nil {
                    let metadataToInsert = BackupLocalFileAttachmentMetadataRecord(
                        attachmentRowId: attachmentRecordId,
                        localKey: Randomness.generateRandomBytes(64),
                        unencryptedByteCount: unencryptedByteCount,
                    )
                    failIfThrows {
                        try metadataToInsert.insert(tx.database)
                    }
                }
                return .more

            },
            concludeTx: { tx, txContext in
                if txContext.didFinish {
                    kvStore.removeValue(forKey: StoreKeys.lastEnumeratedAttachmentIdKey, tx: tx)
                } else if let lastEnumeratedAttachmentId = txContext.lastEnumeratedAttachmentId {
                    kvStore.writeValue(lastEnumeratedAttachmentId, forKey: StoreKeys.lastEnumeratedAttachmentIdKey, tx: tx)
                }
            },
        )
    }

    /// - Parameter localBackupURL
    /// The location chosen by the user to store the top level SignalBackups file.
    func copyBackupToDisk(
        backupTempFileURL: URL,
        messageRootBackupKey: MessageRootBackupKey,
        localBackupURL: URL,
    ) async throws -> (URL, String) {
        let metadataProtoData = try buildMetadataProto(messageRootBackupKey: messageRootBackupKey).serializedData()

        try makeInitialDirectoryStructureIfNeeded(at: localBackupURL)

        let backupsRootDirectory = localBackupURL.appendingPathComponent(LocalFileBackupManager.FileStructure.rootDirectory.rawValue)

        let fileCoordinator = NSFileCoordinator()
        let currentBackupDirectoryName = FileStructure.backupDirectory(date: dateProvider())
        try fileCoordinator.coordinateThrows(writingItemAt: backupsRootDirectory, options: [], by: { writeURL in
            let currentBackupDirectory = writeURL
                .appendingPathComponent(currentBackupDirectoryName)
            let backupFileURL = currentBackupDirectory.appendingPathComponent(LocalFileBackupManager.FileStructure.backupFile.rawValue)
            let metadataFileURL = currentBackupDirectory.appendingPathComponent(LocalFileBackupManager.FileStructure.metadataFile.rawValue)

            try FileManager.default.createDirectory(
                at: currentBackupDirectory,
                withIntermediateDirectories: true,
                attributes: nil,
            )

            try FileManager.default.copyItem(at: backupTempFileURL, to: backupFileURL)

            try metadataProtoData.write(to: metadataFileURL)
        })

        return (backupsRootDirectory, currentBackupDirectoryName)
    }

    private func makeInitialDirectoryStructureIfNeeded(at url: URL) throws {
        let fileCoordinator = NSFileCoordinator()

        let outerDirectoryName = FileStructure.rootDirectory.rawValue
        let outerDirectoryURL = url.appendingPathComponent(outerDirectoryName, isDirectory: true)

        try fileCoordinator.coordinateThrows(writingItemAt: outerDirectoryURL, options: [], by: { writeURL in
            try FileManager.default.createDirectory(
                at: writeURL,
                withIntermediateDirectories: true,
                attributes: nil,
            )

            let filesDirectoryURL = writeURL.appendingPathComponent(FileStructure.attachmentDirectory.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(
                at: filesDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil,
            )
        })
    }

    // MARK: - Choosing backup location

    public func promptUserToChooseFileLocation(fromViewController: UIViewController) {
        let pickerController = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false,
        )
        pickerController.delegate = self

        fromViewController.present(pickerController, animated: true)
    }

    /// Security-scoped bookmarks let us access files persistently once the user chooses a location.
    /// Before accessing a url created by resolving bookmark data, url.startAccessingSecurityScopedResource() must
    /// be called. url.stopAccessingSecurityScopedResource() must be called once access is complete to avoid
    /// leaking kernel resources.
    public func getSavedSecurityScopedBookmark() throws -> URL {
        guard let bookmarkData = db.read(block: { tx in kvStore.fetchValue(Data.self, forKey: StoreKeys.bookmarkDataKey, tx: tx) }) else {
            throw OWSAssertionError("No bookmark data stored")
        }

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale,
        )

        if isStale {
            // TODO: [KC] Prompt user to pick a new location
            throw OWSAssertionError("Unable to resolve url bookmark, location is stale")
        }

        return resolvedURL
    }

    public func saveSecurityScopedBookmark(url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
        db.write { tx in
            kvStore.writeValue(bookmarkData, forKey: StoreKeys.bookmarkDataKey, tx: tx)
        }
    }

    // MARK: - UIDocumentPickerDelegate

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        // The bookmark data has to be written when we have access to the security scoped resource.
        guard url.startAccessingSecurityScopedResource() else {
            Logger.error("Failed to start security scoped access")
            return
        }

        defer { url.stopAccessingSecurityScopedResource() }

        do {
            try saveSecurityScopedBookmark(url: url)
        } catch {
            // TODO: [KC] show error screen.
            logger.error("Failed to save bookmark: \(error)")
        }
    }
}
