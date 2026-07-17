//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import LibSignalClient
@testable import SignalServiceKit

typealias Attachment = SignalServiceKit.Attachment

struct LocalFileBackupManagerTests {
    private let localFileBackupManager: LocalFileBackupManager
    private let db = InMemoryDB()
    private let attachmentStore = AttachmentStore()
    private let backupArchiveManager = BackupArchiveManagerMock()

    init() {
        self.localFileBackupManager = LocalFileBackupManager(
            db: db,
            dateProvider: { Date() },
            attachmentStore: attachmentStore,
        )
    }

    func insertMockAttachment(_ attachment: Attachment) -> Attachment.IDType {
        return db.write { tx in
            var record = Attachment.Record(attachment: attachment)
            try! record.insert(tx.database)
            return record.sqliteId!
        }
    }

    @Test
    func testEnsureMetadataExists() async throws {
        let encryptedSize: UInt32 = 20
        let unencryptedSize: UInt32 = 32

        let mockAttachment = AttachmentStream.mock(
            streamInfo: .mock(
                encryptedByteCount: encryptedSize,
                unencryptedByteCount: unencryptedSize,
            ),
        ).attachment

        let id = insertMockAttachment(mockAttachment)

        await localFileBackupManager.ensureAttachmentMetadataExists()

        let metadata = try db.read { tx in
            try BackupLocalFileAttachmentMetadataRecord
                .filter(Column(BackupLocalFileAttachmentMetadataRecord.CodingKeys.attachmentRowId) == id)
                .fetchOne(tx.database)
        }

        #expect(metadata != nil)
    }

    @Test
    func testQueueAttachments() async throws {
        let encryptedSize: UInt32 = 20
        let unencryptedSize: UInt32 = 32

        let mockAttachment1 = AttachmentStream.mock(
            streamInfo: .mock(
                encryptedByteCount: encryptedSize,
                unencryptedByteCount: unencryptedSize,
            ),
        ).attachment

        let mockAttachment2 = AttachmentStream.mock(
            streamInfo: .mock(
                encryptedByteCount: encryptedSize,
                unencryptedByteCount: unencryptedSize,
            ),
        ).attachment

        let id1 = insertMockAttachment(mockAttachment1)
        let id2 = insertMockAttachment(mockAttachment2)

        let localFileBackupAttachmentCollector = LocalFileBackupAttachmentCollector()
        localFileBackupAttachmentCollector.append(id: id1)
        localFileBackupAttachmentCollector.append(id: id2)

        try await localFileBackupManager.queueLocalBackupAttachmentsForExport(localFileBackupAttachmentCollector: localFileBackupAttachmentCollector)

        let attachments = try db.read { tx in
            try BackupLocalFileAttachmentExportRecord
                .fetchAll(tx.database)
        }

        #expect(attachments.count == 2)
        let attachmentIds = Set(attachments.map(\.attachmentRowId))
        #expect(attachmentIds.contains(id1))
        #expect(attachmentIds.contains(id2))
    }

    @Test
    func testCopyBackupToDisk() async throws {
        let localIdentifiers = LocalIdentifiers.forUnitTests
        let aep = AccountEntropyPool()

        let backupKey = try MessageRootBackupKey(accountEntropyPool: aep, aci: localIdentifiers.aci)

        let backupFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data("test".utf8).write(to: backupFile)

        let localBackupURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: localBackupURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: localBackupURL)
            try? FileManager.default.removeItem(at: backupFile)
        }

        let (backupsRootDirectory, currentBackupDirectoryName) = try await localFileBackupManager.copyBackupToDisk(
            backupTempFileURL: backupFile,
            messageRootBackupKey: backupKey,
            localBackupURL: localBackupURL,
        )

        let currentBackupPath = backupsRootDirectory.appendingPathComponent(currentBackupDirectoryName)
        let mainFilePath = currentBackupPath.appendingPathComponent("main")
        let metadataFilePath = currentBackupPath.appendingPathComponent("metadata")

        #expect(FileManager.default.fileExists(atPath: backupsRootDirectory.path))
        #expect(FileManager.default.fileExists(atPath: currentBackupPath.path))
        #expect(FileManager.default.fileExists(atPath: mainFilePath.path))
        #expect(FileManager.default.fileExists(atPath: metadataFilePath.path))

        let metadataFileContents = try Data(contentsOf: metadataFilePath)
        let metadataProto = try LocalBackupProto_Metadata(serializedBytes: metadataFileContents)

        #expect(metadataProto.version == 1)
        let localBackupMetadataKey = backupKey.backupKey.deriveLocalBackupMetadataKey()
        let iv = metadataProto.backupID.iv
        let nonce = iv + Data(count: 4) // Last 4 bytes are 0 for the counter.
        var decryptedBackupId = metadataProto.backupID.encryptedID
        try Aes256Ctr32.process(&decryptedBackupId, key: localBackupMetadataKey, nonce: nonce)

        #expect(decryptedBackupId == backupKey.backupId)
    }

    func makeMockAttachmentWithRealFile() throws -> Attachment {
        let key = AttachmentKey.generate()
        let plaintextData = Data("test".utf8)
        let localRelativeFilePath = AttachmentStream.newRelativeFilePath()

        let plaintextURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try plaintextData.write(to: plaintextURL)
        defer { try? FileManager.default.removeItem(at: plaintextURL) }

        let attachmentFileURL = AttachmentStream.absoluteAttachmentFileURL(relativeFilePath: localRelativeFilePath)
        try FileManager.default.createDirectory(
            at: attachmentFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let encryptionMetadata = try Cryptography.encryptAttachment(
            at: plaintextURL,
            output: attachmentFileURL,
            attachmentKey: key,
        )

        return AttachmentStream.mock(
            streamInfo: .mock(
                encryptionKey: key,
                encryptedByteCount: UInt32(clamping: encryptionMetadata.encryptedLength),
                unencryptedByteCount: UInt32(plaintextData.count),
                localRelativeFilePath: localRelativeFilePath,
            ),
        ).attachment
    }

    @Test
    func testCopyAttachmentsToDisk() async throws {
        let mockAttachment1 = try makeMockAttachmentWithRealFile()
        let mockAttachment2 = try makeMockAttachmentWithRealFile()

        let id1 = insertMockAttachment(mockAttachment1)
        let id2 = insertMockAttachment(mockAttachment2)

        await localFileBackupManager.ensureAttachmentMetadataExists()

        let localFileBackupAttachmentCollector = LocalFileBackupAttachmentCollector()
        localFileBackupAttachmentCollector.append(id: id1)
        localFileBackupAttachmentCollector.append(id: id2)

        try await localFileBackupManager.queueLocalBackupAttachmentsForExport(localFileBackupAttachmentCollector: localFileBackupAttachmentCollector)

        let localBackupURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: localBackupURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: localBackupURL)
        }

        let currentBackupDirectoryName = LocalFileBackupManager.FileStructure.backupDirectory(date: Date())
        let currentBackupDir = localBackupURL.appendingPathComponent(currentBackupDirectoryName)
        try FileManager.default.createDirectory(at: currentBackupDir, withIntermediateDirectories: true)

        let filesDir = localBackupURL.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let filesMetadata = localBackupURL
            .appendingPathComponent(currentBackupDirectoryName)
            .appendingPathComponent("files")

        try await localFileBackupManager.writeQueuedAttachmentsToDisk(
            backupsRootDirectory: localBackupURL,
            currentBackupDirectoryName: currentBackupDirectoryName,
        )

        #expect(FileManager.default.fileExists(atPath: filesDir.path))
        #expect(FileManager.default.fileExists(atPath: filesMetadata.path))

        let localKey1 = try db.read { tx in
            try BackupLocalFileAttachmentMetadataRecord
                .filter(key: id1)
                .fetchOne(tx.database)!.localKey
        }

        let localKey2 = try db.read { tx in
            try BackupLocalFileAttachmentMetadataRecord
                .filter(key: id2)
                .fetchOne(tx.database)!.localKey
        }

        let mediaName1 = await localFileBackupManager.mediaNameForAttachment(
            localKey: localKey1,
            plaintextHash: mockAttachment1.plaintextHash!,
        )
        let mediaName2 = await localFileBackupManager.mediaNameForAttachment(
            localKey: localKey2,
            plaintextHash: mockAttachment2.plaintextHash!,
        )

        let mediaNameDir1 = filesDir.appendingPathComponent(String(mediaName1.prefix(2)))
        let mediaNameDir2 = filesDir.appendingPathComponent(String(mediaName2.prefix(2)))

        #expect(FileManager.default.fileExists(atPath: mediaNameDir1.path))
        #expect(FileManager.default.fileExists(atPath: mediaNameDir2.path))

        let mediaPath1 = mediaNameDir1.appendingPathComponent(mediaName1)
        let mediaPath2 = mediaNameDir2.appendingPathComponent(mediaName2)

        #expect(FileManager.default.fileExists(atPath: mediaPath1.path))
        #expect(FileManager.default.fileExists(atPath: mediaPath2.path))
    }
}
