//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation
import GRDB
import SignalServiceKit

protocol DeviceTransferServiceObserver: AnyObject {
    func deviceTransferServiceDiscoveredNewDevice(peerId: DeviceTransferPeerID, discoveryInfo: [String: String]?)

    func deviceTransferServiceDidStartTransfer(progress: Progress)
    func deviceTransferServiceDidEndTransfer(error: DeviceTransfer.Error?)

    func deviceTransferServiceDidRequestAppRelaunch()
}

protocol DeviceTransferServiceProtocol {
    func startAcceptingTransfersFromOldDevices(mode: DeviceTransfer.Mode) throws -> URL
    func addObserver(_ observer: DeviceTransferServiceObserver)
    func removeObserver(_ observer: DeviceTransferServiceObserver)
    func stopAcceptingTransfersFromOldDevices()
    func cancelTransferFromOldDevice()
}

class DeviceTransferService:
    DeviceTransferServiceProtocol,
    DeviceTransferSessionDelegate,
    DeviceTransferServiceBrowserDelegate
{

    private let serialQueue = DispatchQueue(label: "org.signal.device-transfer")
    private var _transferState: TransferState = .idle
    var transferState: TransferState {
        get { serialQueue.sync { _transferState } }
        set { serialQueue.sync { _transferState = newValue } }
    }

    private let sleepBlockObject = DeviceSleepBlockObject(blockReason: "device transfer")
    private var throughputMonitor: ThroughputMonitor?

    private lazy var newDeviceServiceBrowser = {
        MPCDeviceTransfer.Browser(peerId: DeviceTransferPeerID(displayName: UUID().uuidString))
    }()

    private lazy var newDeviceServiceAdvertiser = {
        MPCDeviceTransfer.Advertiser(peerId: DeviceTransferPeerID(displayName: UUID().uuidString))
    }()

    // MARK: -

    let appReadiness: AppReadiness
    let deviceSleepManager: DeviceSleepManagerImpl
    let keychainStorage: any KeychainStorage
    let deviceTransferRestore: any DeviceTransferRestore

    init(
        appReadiness: AppReadiness,
        deviceSleepManager: DeviceSleepManagerImpl,
        deviceTransferRestore: any DeviceTransferRestore,
        keychainStorage: any KeychainStorage,
    ) {
        self.appReadiness = appReadiness
        self.deviceSleepManager = deviceSleepManager
        self.deviceTransferRestore = deviceTransferRestore
        self.keychainStorage = keychainStorage

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: .OWSApplicationDidEnterBackground,
            object: nil,
        )
    }

    // MARK: - New Device

    func startAcceptingTransfersFromOldDevices(mode: DeviceTransfer.Mode) throws -> URL {
        Task {
            await self.deviceSleepManager.addBlock(blockObject: sleepBlockObject)
        }

        var session = try newDeviceServiceAdvertiser.startAdvertising()
        session.delegate = self

        return try MPCDeviceTransfer.Advertiser.urlForTransfer(
            identity: session.identity,
            localPeerId: session.peerId,
            mode: mode,
        )
    }

    func stopAcceptingTransfersFromOldDevices() {
        newDeviceServiceAdvertiser.stopAdvertising()
    }

    func cancelTransferFromOldDevice() {
        AssertIsOnMainThread()

        guard case .incoming = transferState else { return }

        notifyObservers { $0.deviceTransferServiceDidEndTransfer(error: .cancel) }

        stopTransfer()
    }

    // MARK: - Old Device

    func startListeningForNewDevices() {
        newDeviceServiceBrowser.delegate = self
        newDeviceServiceBrowser.startBrowsing()
    }

    func stopListeningForNewDevices() {
        newDeviceServiceBrowser.stopBrowsing()
    }

    func transferAccountToNewDevice(with peerId: DeviceTransferPeerID, certificateHash: Data) throws {
        cancelTransferToNewDevice()

        // Marking the transfer as "in progress" does a few things, most notably it:
        //   * prevents any WAL checkpoints while the transfer is in progress
        //   * causes the device to behave is if it's not registered
        DependenciesBridge.shared.db.write { tx in
            DependenciesBridge.shared.registrationStateChangeManager.setIsTransferInProgress(tx: tx)
        }

        defer {
            // If we failed to start the transfer, clear the transfer in progress flag
            if case .idle = transferState {
                DependenciesBridge.shared.db.write { tx in
                    DependenciesBridge.shared.registrationStateChangeManager.setIsTransferComplete(
                        sendStateUpdateNotification: true,
                        tx: tx,
                    )
                }
            }
        }

        let manifest = try buildManifest()
        let progress = Progress(totalUnitCount: Int64(manifest.estimatedTotalSize))

        Task { @MainActor in
            throughputMonitor = ThroughputMonitor(progress: progress)
            deviceSleepManager.addBlock(blockObject: sleepBlockObject)
        }

        transferState = .outgoing(
            newDevicePeerId: peerId,
            newDeviceCertificateHash: certificateHash,
            manifest: manifest,
            transferredFileIds: [],
            progress: progress,
        )

        var session = try newDeviceServiceBrowser.invitePeer(peerId)
        session.delegate = self
    }

    func cancelTransferToNewDevice() {
        guard case .outgoing = transferState else { return }

        notifyObservers { $0.deviceTransferServiceDidEndTransfer(error: .cancel) }

        stopTransfer()
    }

    // MARK: - Observation

    private var observers = [Weak<DeviceTransferServiceObserver>]()
    func addObserver(_ observer: DeviceTransferServiceObserver) {
        observers.append(Weak(value: observer))
    }

    func removeObserver(_ observer: DeviceTransferServiceObserver) {
        observers.removeAll { return $0.value === observer }
    }

    func notifyObservers(_ block: @escaping (DeviceTransferServiceObserver) -> Void) {
        DispatchMainThreadSafe {
            self.observers.compactMap { $0.value }.forEach { block($0) }
        }
    }

    // MARK: -

    func failTransfer(_ error: DeviceTransfer.Error, _ reason: String) {
        Logger.error("Failed transfer \(reason)")

        stopTransfer()

        notifyObservers { $0.deviceTransferServiceDidEndTransfer(error: error) }
    }

    func stopTransfer(notifyRegState: Bool = true) {
        switch transferState {
        case .outgoing:
            sendTask?.cancel()
            stopListeningForNewDevices()
        case .incoming:
            stopAcceptingTransfersFromOldDevices()
        case .idle:
            break
        }

        Task { @MainActor in
            throughputMonitor?.stop()
            deviceSleepManager.removeBlock(blockObject: sleepBlockObject)
        }

        // It is possible that we get here because the app was backgrounded
        // after a failed launch. In that case, `tsAccountManager` will not be
        // available, and setting this will crash. It'd probably be safe to more
        // simply return in the .idle case above since none of the values being
        // reset should have values if we are idle, but I am scared of it.
        if case .idle = transferState {} else {
            DependenciesBridge.shared.db.write { tx in
                DependenciesBridge.shared.registrationStateChangeManager.setIsTransferComplete(
                    sendStateUpdateNotification: notifyRegState,
                    tx: tx,
                )
            }
        }

        transferState = .idle
    }

    // MARK: -

    @objc
    private func didEnterBackground() {
        // MCSession automatically disconnects when the app is backgrounded.
        // Send an explicit message to the peer (if connected) telling them
        // that's what happened.
        switch transferState {
        case .idle:
            break
        case .incoming(let oldDevicePeerId, _, _, _, _):
            if let session = newDeviceServiceBrowser.session {
                try? sendBackgroundAppMessage(to: oldDevicePeerId, session: session)
            }
            notifyObservers { $0.deviceTransferServiceDidEndTransfer(error: .backgroundedDevice) }
        case .outgoing(let newDevicePeerId, _, _, _, _):
            if let session = newDeviceServiceBrowser.session {
                try? sendBackgroundAppMessage(to: newDevicePeerId, session: session)
            }
            notifyObservers { $0.deviceTransferServiceDidEndTransfer(error: .backgroundedDevice) }
        }
        stopTransfer()
    }

    // MARK: - Sending

    private var sendTask: Task<Void, any Swift.Error>?
    func sendAllFiles(session: DeviceTransferSession) throws {
        self.sendTask = Task {
            do {
                try await self._sendAllFiles(session: session)
            } catch is CancellationError {
                // Nothing to do.
            } catch {
                self.failTransfer(.assertion, "\(error)")
            }
        }
    }

    @MainActor
    private func _sendAllFiles(session: DeviceTransferSession) async throws {
        guard case .outgoing(let newDevicePeerId, _, let manifest, _, _) = transferState else {
            throw OWSAssertionError("Attempted to send files while no transfer in progress")
        }

        guard let database = manifest.database else {
            throw OWSAssertionError("Manifest unexpectedly missing database")
        }

        struct DatabaseCopy {
            let db: DeviceTransferProtoFile
            let wal: DeviceTransferProtoFile
        }

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                // Make a copy of the database files within a write transaction so we can be confident
                // they aren't mutated during the copy. We then transfer these copies.
                let dbCopy = try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                    // The MultipeerConnectivity framework stalls if we try to send an empty
                    // file. The receiver requires a non-empty file. We can't send garbage
                    // (because that would corrupt the database), so mutate the database, force
                    // it to be written to the WAL file, and then send that result to our peer.
                    let store = NewKeyValueStore(collection: "DeviceTransferWAL")
                    store.writeValue(Randomness.generateRandomBytes(32), forKey: "MustBeNonEmpty", tx: tx)
                    store.removeValue(forKey: "MustBeNonEmpty", tx: tx)
                    sqlite3_db_cacheflush(tx.database.sqliteConnection!)
                    do {
                        let dbCopy = try Self.makeLocalCopy(databaseFile: database.database)
                        let walCopy = try Self.makeLocalCopy(databaseFile: database.wal)
                        return DatabaseCopy(db: dbCopy, wal: walCopy)
                    } catch {
                        Logger.error("Failed to copy database files!")
                        throw error
                    }
                }
                defer {
                    for databaseFile in [dbCopy.db, dbCopy.wal] {
                        if let copyUrl = try? Self.urlForCopy(databaseFile: databaseFile) {
                            try? OWSFileSystem.deleteFile(url: copyUrl)
                        }
                    }
                }
                for databaseFile in [dbCopy.db, dbCopy.wal] {
                    try await DeviceTransferOperation(
                        session: session,
                        file: databaseFile,
                    ).run()
                }
            }
            for (index, file) in manifest.files.enumerated() {
                if index >= 10 {
                    // If we've already kicked off 10, wait for one to finish before starting the next.
                    try await taskGroup.next()
                }
                taskGroup.addTask {
                    try await DeviceTransferOperation(
                        session: session,
                        file: file,
                    ).run()
                }
            }
            // Make sure to wait for whatever's left at the end.
            try await taskGroup.waitForAll()
        }

        await DependenciesBridge.shared.db.awaitableWrite { tx in
            DependenciesBridge.shared.registrationStateChangeManager.setWasTransferred(tx: tx)
        }

        try self.sendDoneMessage(to: newDevicePeerId, session: session)
    }

    private static let dbCopyFilename = "db_copy_for_transfer"
    private static let walCopyFilename = "wal_copy_for_transfer"

    private static func urlForCopy(
        databaseFile: DeviceTransferProtoFile,
    ) throws -> URL {
        let newFileName: String
        let newFileExtension: String
        if databaseFile.identifier == DeviceTransfer.Constants.databaseIdentifier {
            newFileName = Self.dbCopyFilename
            newFileExtension = ".sqlite"
        } else if databaseFile.identifier == DeviceTransfer.Constants.databaseWALIdentifier {
            newFileName = Self.walCopyFilename
            newFileExtension = ".sqlite-wal"
        } else {
            throw OWSAssertionError("Unknown db file being copied")
        }
        owsAssertDebug(databaseFile.relativePath.hasSuffix(newFileExtension))
        return OWSFileSystem.temporaryFileUrl(
            fileName: newFileName,
            fileExtension: newFileExtension,
            isAvailableWhileDeviceLocked: false,
        )
    }

    private static func makeLocalCopy(
        databaseFile: DeviceTransferProtoFile,
    ) throws -> DeviceTransferProtoFile {
        let url = URL(
            fileURLWithPath: databaseFile.relativePath,
            relativeTo: DeviceTransfer.Constants.appSharedDataDirectory,
        )

        if !OWSFileSystem.fileOrFolderExists(url: url) {
            throw OWSAssertionError("Mandatory database file is missing for transfer")
        }

        let copyUrl = try Self.urlForCopy(databaseFile: databaseFile)

        if OWSFileSystem.fileOrFolderExists(url: copyUrl) {
            // We might have partially copied before. Delete it.
            try OWSFileSystem.deleteFile(url: copyUrl)
        }
        try OWSFileSystem.copyFile(from: url, to: copyUrl)

        // Note that the receiver doesn't care about the relative path
        // for database files (it does care for other files!) because it
        // forces the path to be that to its own local database.
        var protoBuilder = databaseFile.asBuilder()
        protoBuilder.setRelativePath(copyUrl.relativePath)
        return protoBuilder.buildInfallibly()
    }

    func sendDoneMessage(to peerId: DeviceTransferPeerID, session: DeviceTransferSession) throws {
        Logger.info("Sending done message")
        try session.send(DeviceTransfer.Message.done.data, toPeers: [peerId], with: .reliable)
    }

    func sendBackgroundAppMessage(to peerId: DeviceTransferPeerID, session: DeviceTransferSession) throws {
        Logger.info("Sending backgrounded message")
        try session.send(DeviceTransfer.Message.backgroundApp.data, toPeers: [peerId], with: .unreliable)
    }

    // MARK: - DeviceTransferSessionDelegate

    func session(
        _ session: DeviceTransferSession,
        peer peerId: DeviceTransferPeerID,
        didChange state: TransferSessionState,
    ) {
        // dispatch to main ASAP to free up the session's private thread to receive more bytes.
        Task { @MainActor in
            Logger.debug("Connection to \(peerId) did change: \(state.rawValue)")

            switch self.transferState {
            case .outgoing(let newDevicePeerId, _, _, let transferredFiles, let progress):
                // We only care about state changes for the device we're sending to.
                guard peerId == newDevicePeerId else { return }

                Logger.info("Connection to new device did change: \(state.rawValue)")

                switch state {
                case .connected:
                    self.notifyObservers { $0.deviceTransferServiceDidStartTransfer(progress: progress) }

                    // Only send the files if we haven't yet sent the manifest.
                    guard !transferredFiles.contains(DeviceTransfer.Constants.manifestIdentifier) else { return }

                    do {
                        try await self.sendManifest(session: session)
                        try self.sendAllFiles(session: session)
                    } catch {
                        self.failTransfer(.assertion, "Failed to send manifest to new device \(error)")
                    }
                case .connecting:
                    break
                case .notConnected:
                    self.failTransfer(.assertion, "Lost connection to new device")
                @unknown default:
                    self.failTransfer(.assertion, "Unexpected connection state: \(state.rawValue)")
                }
            case .incoming(let oldDevicePeerId, _, _, _, _):
                // We only care about state changes for the device we're receiving from.
                guard peerId == oldDevicePeerId else { return }

                if state == .notConnected { self.failTransfer(.assertion, "Lost connection to old device") }
            case .idle:
                break
            }
        }
    }

    func session(
        _ session: DeviceTransferSession,
        didReceive data: Data,
        fromPeer peerId: DeviceTransferPeerID,
    ) {
        switch transferState {
        case .idle:
            break

        case .outgoing(let newDevicePeerId, _, _, _, _):
            guard peerId == newDevicePeerId else {
                return owsFailDebug("Ignoring data from unexpected peer \(peerId)")
            }

            switch data {
            case DeviceTransfer.Message.backgroundApp.data:
                return failTransfer(.backgroundedDevice, "Received terminate message")
            case DeviceTransfer.Message.done.data:
                break
            default:
                return failTransfer(.assertion, "Received unexpected data")
            }

            // Notify the UI that the transfer completed successfully.
            notifyObservers { $0.deviceTransferServiceDidEndTransfer(error: nil) }

            stopTransfer()

            // When the old device receives the done message from the new device,
            // it can be confident that the transfer has completed successfully and
            // clear out all data from this device. This will crash the app.
            Task { @MainActor in
                SignalApp.shared.resetAppData(keyFetcher: SSKEnvironment.shared.databaseStorageRef.keyFetcher)
                SignalApp.shared.showTransferCompleteAndExit()
            }

        case .incoming(let oldDevicePeerId, _, let receivedFileIds, let skippedFileIds, _):
            guard peerId == oldDevicePeerId else {
                return owsFailDebug("Ignoring data from unexpected peer \(peerId)")
            }

            switch data {
            case DeviceTransfer.Message.backgroundApp.data:
                return failTransfer(.backgroundedDevice, "Received backgrounded message")
            case DeviceTransfer.Message.done.data:
                break
            default:
                return failTransfer(.assertion, "Received unexpected data")
            }

            Task { @MainActor in
                throughputMonitor?.stop()
            }

            // When the new device receives the done message from the old device,
            // it indicates that the old device thinks we should have received
            // everything at this point.

            guard
                verifyTransferCompletedSuccessfully(
                    receivedFileIds: receivedFileIds,
                    skippedFileIds: skippedFileIds,
                )
            else {
                return failTransfer(.assertion, "transfer is missing data")
            }

            // Record that we have a pending restore, so even if the app exits
            // we can still know to restore the data that was transferred.
            deviceTransferRestore.markPendingRestore()

            // Try and notify the old device that we agree, everything is done.
            // At this point, we consider the transfer complete regardless of
            // whether or not this message is received by the old device. If the
            // old device misses this message (because the app crashes, etc.) it
            // will continue acting as if it is "unregistered", but it won't delete
            // all data because it doesn't know for sure if the data was safely
            // received by the new device.
            do {
                try sendDoneMessage(to: oldDevicePeerId, session: session)
            } catch {
                owsFailDebug("Failed to send done message to old device \(error)")
            }

            // Notify the UI that the transfer completed successfully.
            notifyObservers { $0.deviceTransferServiceDidEndTransfer(error: nil) }

            // Try and restore the received data. If for some reason the app exits
            // or crashes at this point, we will retry the restore when the app next
            // launches.
            do {
                try deviceTransferRestore.restoreTransferredData()
            } catch {
                owsFail("Restore failed. Will try again on next launch. Error: \(error)")
            }

            stopTransfer(notifyRegState: false)

            Logger.info("Transfer complete")

            DispatchQueue.main.async {
                self.notifyObservers { $0.deviceTransferServiceDidRequestAppRelaunch() }
            }
        }
    }

    func session(
        _ session: DeviceTransferSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerId: DeviceTransferPeerID,
        with fileProgress: Progress,
    ) {
        switch transferState {
        case .idle:
            guard resourceName == DeviceTransfer.Constants.manifestIdentifier else {
                return Logger.info("Ignoring unexpected incoming file \(resourceName)")
            }
        case .outgoing:
            owsFailDebug("Unexpectedly received a file on old device \(resourceName)")
        case .incoming(let oldDevicePeerId, let manifest, let receivedFileIds, let skippedFileIds, let progress):
            guard peerId == oldDevicePeerId else {
                return owsFailDebug("Ignoring file from unexpected peer \(peerId)")
            }

            let nameComponents = resourceName.components(separatedBy: " ")

            guard let fileIdentifier = nameComponents.first, nameComponents.count == 2 else {
                return owsFailDebug("Received incorrectly formatted resourceName: \(resourceName)")
            }

            guard !receivedFileIds.contains(fileIdentifier) else {
                return Logger.info("Ignoring duplicate file: \(fileIdentifier)")
            }

            guard !skippedFileIds.contains(fileIdentifier) else {
                return Logger.info("Ignoring previously skipped file: \(fileIdentifier)")
            }

            guard
                let file: DeviceTransferProtoFile = {
                    switch fileIdentifier {
                    case DeviceTransfer.Constants.databaseIdentifier:
                        return manifest.database?.database
                    case DeviceTransfer.Constants.databaseWALIdentifier:
                        return manifest.database?.wal
                    default:
                        return manifest.files.first(where: { $0.identifier == fileIdentifier })
                    }
                }()
            else {
                return owsFailDebug("Received unexpected file on new device: \(fileIdentifier)")
            }

            Logger.info("Receiving file: \(file.identifier), estimatedSize: \(file.estimatedSize)")
            progress.addChild(fileProgress, withPendingUnitCount: Int64(file.estimatedSize))
        }
    }

    func session(
        _ session: DeviceTransferSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerId: DeviceTransferPeerID,
        at localURL: URL?,
        withError error: Swift.Error?,
    ) {
        switch transferState {
        case .idle:
            guard resourceName == DeviceTransfer.Constants.manifestIdentifier else {
                return Logger.info("Ignoring unexpected incoming file \(resourceName)")
            }

            if let error {
                owsFailDebug("Failed to receive manifest \(error)")
            } else if let localURL {
                handleReceivedManifest(at: localURL, fromPeer: peerId)
            } else {
                owsFailDebug("Unexpectedly completed transfer of resource with no URL or error")
            }
        case .outgoing:
            owsFailDebug("Unexpectedly received a file on old device \(resourceName)")
        case .incoming(let oldDevicePeerId, let manifest, let receivedFileIds, let skippedFileIds, _):
            guard peerId == oldDevicePeerId else {
                return owsFailDebug("Ignoring file from unexpected peer \(peerId)")
            }

            let nameComponents = resourceName.components(separatedBy: " ")

            guard let fileIdentifier = nameComponents.first, let fileHash = nameComponents.last, nameComponents.count == 2 else {
                return owsFailDebug("Received incorrectly formatted resourceName: \(resourceName)")
            }

            guard !receivedFileIds.contains(fileIdentifier) else {
                return Logger.info("Ignoring duplicate file: \(fileIdentifier)")
            }

            guard !skippedFileIds.contains(fileIdentifier) else {
                return Logger.info("Ignoring previously skipped file: \(fileIdentifier)")
            }

            guard
                let file: DeviceTransferProtoFile = {
                    switch fileIdentifier {
                    case DeviceTransfer.Constants.databaseIdentifier:
                        return manifest.database?.database
                    case DeviceTransfer.Constants.databaseWALIdentifier:
                        return manifest.database?.wal
                    default:
                        return manifest.files.first(where: { $0.identifier == fileIdentifier })
                    }
                }()
            else {
                return owsFailDebug("Received unexpected file on new device: \(fileIdentifier)")
            }

            if let error {
                failTransfer(.assertion, "Failed to receive file \(file.identifier) \(error)")
            } else if let localURL {
                OWSFileSystem.ensureDirectoryExists(DeviceTransfer.Constants.pendingTransferFilesDirectory.path)

                guard let computedHash = try? Cryptography.computeSHA256DigestOfFile(at: localURL) else {
                    return failTransfer(.assertion, "Failed to compute hash for \(file.identifier)")
                }

                guard computedHash.hexadecimalString == fileHash else {
                    return failTransfer(.assertion, "Received file with incorrect hash \(file.identifier)")
                }

                guard computedHash != DeviceTransfer.Constants.missingFileHash else {
                    Logger.warn("Received notification of missing file: \(file.identifier), skipping.")
                    transferState = transferState.appendingSkippedFileId(file.identifier)
                    return
                }

                do {
                    try OWSFileSystem.moveFilePath(
                        localURL.path,
                        toFilePath: URL(
                            fileURLWithPath: file.identifier,
                            relativeTo: DeviceTransfer.Constants.pendingTransferFilesDirectory,
                        ).path,
                    )
                } catch {
                    Logger.warn("Couldn't move file: \(error.shortDescription)")
                    return failTransfer(.assertion, "Failed to move file into place \(file.identifier)")
                }

                Logger.info("Received file: \(file.identifier)")
                transferState = transferState.appendingFileId(file.identifier)
            } else {
                owsFailDebug("Unexpectedly completed transfer of resource with no URL or error")
            }
        }
    }

    func session(
        _ session: DeviceTransferSession,
        didReceiveCertificates certificates: [Any]?,
        fromPeer peerId: DeviceTransferPeerID,
        certificateHandler: @escaping (Bool) -> Void,
    ) {
        var certificateIsTrusted = false

        defer {
            certificateHandler(certificateIsTrusted)
            if !certificateIsTrusted {
                self.failTransfer(.certificateMismatch, "the received certificate did not match the expected certificate")
            }
        }

        guard case .outgoing(let newDevicePeerId, let expectedCertificateHash, _, _, _) = transferState else {
            // Accept all connections if we're not doing an outgoing transfer AND we aren't yet registered.
            // Registered devices can only ever perform outgoing transfers.
            certificateIsTrusted = !DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered
            return
        }

        // Reject any connections from unexpected devices.
        guard peerId == newDevicePeerId else { return }

        // Verify the received certificate matches the expected certificate.
        guard let certificate = certificates?.first else {
            return owsFailDebug("new connection did not provide any certificate")
        }

        let certificateData = SecCertificateCopyData(certificate as! SecCertificate) as Data

        // Reject any connections where we can't compute the certificate hash
        let certificateHash = Data(SHA256.hash(data: certificateData))

        // Reject any connections where the certificate doesn't match the expected certificate
        guard expectedCertificateHash.ows_constantTimeIsEqual(to: certificateHash) else {
            return owsFailDebug("connection from known peer \(peerId) using unexpected certificate")
        }

        Logger.info("Successfully verified new device certificate \(peerId)")

        certificateIsTrusted = true
    }

    // MARK: - DeviceTransferServiceBrowserDelegate

    func deviceTransferServiceDiscoveredNewDevice(peerId: DeviceTransferPeerID) {
        notifyObservers { $0.deviceTransferServiceDiscoveredNewDevice(peerId: peerId, discoveryInfo: nil) }
    }

    func buildManifest() throws -> DeviceTransferProtoManifest {
        var manifestBuilder = DeviceTransferProtoManifest.builder(grdbSchemaVersion: UInt64(GRDBSchemaMigrator.grdbSchemaVersionLatest))
        var estimatedTotalSize: UInt64 = 0

        // Database

        do {
            let database: DeviceTransferProtoFile = try {
                let file = SSKEnvironment.shared.databaseStorageRef.grdbStorage.databaseFilePath
                let size = try OWSFileSystem.fileSize(ofPath: file)
                guard size > 0 else {
                    throw OWSAssertionError("database is empty")
                }
                estimatedTotalSize += size
                let fileBuilder = DeviceTransferProtoFile.builder(
                    identifier: DeviceTransfer.Constants.databaseIdentifier,
                    relativePath: try pathRelativeToAppSharedDirectory(file),
                    estimatedSize: size,
                )
                return fileBuilder.buildInfallibly()
            }()

            let wal: DeviceTransferProtoFile = try {
                let file = SSKEnvironment.shared.databaseStorageRef.grdbStorage.databaseWALFilePath
                let size = try OWSFileSystem.fileSize(ofPath: file)
                estimatedTotalSize += size
                let fileBuilder = DeviceTransferProtoFile.builder(
                    identifier: DeviceTransfer.Constants.databaseWALIdentifier,
                    relativePath: try pathRelativeToAppSharedDirectory(file),
                    estimatedSize: size,
                )
                return fileBuilder.buildInfallibly()
            }()

            let databaseBuilder = DeviceTransferProtoDatabase.builder(
                key: try SSKEnvironment.shared.databaseStorageRef.keyFetcher.fetchData(),
                database: database,
                wal: wal,
            )
            manifestBuilder.setDatabase(databaseBuilder.buildInfallibly())
        }

        // Attachments, Avatars, and Stickers

        // TODO: Ideally, these paths would reference constants...
        let foldersToTransfer = ["Attachments/", "ProfileAvatars/", "GroupAvatars/", "StickerManager/", "Wallpapers/", "Library/Sounds/", "AvatarHistory/", "attachment_files/"]
        let filesToTransfer = try foldersToTransfer.flatMap { folder -> [String] in
            let url = URL(fileURLWithPath: folder, relativeTo: DeviceTransfer.Constants.appSharedDataDirectory)
            return try OWSFileSystem.recursiveFilesInDirectory(url.path)
        }

        for file in filesToTransfer {
            let size = try OWSFileSystem.fileSize(ofPath: file)

            guard size > 0 else {
                owsFailDebug("skipping empty file \(file)")
                continue
            }

            estimatedTotalSize += size
            let fileBuilder = DeviceTransferProtoFile.builder(
                identifier: UUID().uuidString,
                relativePath: try pathRelativeToAppSharedDirectory(file),
                estimatedSize: size,
            )
            manifestBuilder.addFiles(fileBuilder.buildInfallibly())
        }

        // Standard Defaults
        func isAppleKey(_ key: String) -> Bool {
            return key.starts(with: "NS") || key.starts(with: "Apple")
        }

        do {
            for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
                // Filter out any keys we think are managed by Apple, we don't need to transfer them.
                guard !isAppleKey(key) else { continue }

                guard let encodedValue = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true) else { continue }

                let defaultBuilder = DeviceTransferProtoDefault.builder(
                    key: key,
                    encodedValue: encodedValue,
                )
                manifestBuilder.addStandardDefaults(defaultBuilder.buildInfallibly())
            }
        }

        // App Defaults

        do {
            for (key, value) in CurrentAppContext().appUserDefaults().dictionaryRepresentation() {
                // Filter out any keys we think are managed by Apple, we don't need to transfer them.
                guard !isAppleKey(key) else { continue }

                guard let encodedValue = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true) else { continue }

                let defaultBuilder = DeviceTransferProtoDefault.builder(
                    key: key,
                    encodedValue: encodedValue,
                )
                manifestBuilder.addAppDefaults(defaultBuilder.buildInfallibly())
            }
        }

        manifestBuilder.setEstimatedTotalSize(estimatedTotalSize)

        return manifestBuilder.buildInfallibly()
    }

    func pathRelativeToAppSharedDirectory(_ path: String) throws -> String {
        guard !path.contains("*") else {
            throw OWSAssertionError("path contains invalid character: *")
        }

        let components = path.components(separatedBy: "/")

        guard components.first != "~" else {
            throw OWSAssertionError("path starts with invalid component: ~")
        }

        for component in components {
            guard component != "." else {
                throw OWSAssertionError("path contains invalid component: .")
            }

            guard component != ".." else {
                throw OWSAssertionError("path contains invalid component: ..")
            }
        }

        var path = path.replacingOccurrences(of: DeviceTransfer.Constants.appSharedDataDirectory.path, with: "")
        if path.starts(with: "/") { path.removeFirst() }
        return path
    }

    func handleReceivedManifest(at localURL: URL, fromPeer peerId: DeviceTransferPeerID) {
        guard case .idle = transferState else {
            stopTransfer()
            return owsFailDebug("Received manifest in unexpected state \(transferState)")
        }
        guard let fileSize = (try? OWSFileSystem.fileSize(of: localURL)) else {
            stopTransfer()
            return owsFailDebug("Missing manifest file.")
        }
        // Not sure why this limit exists in the first place, but 1Gb should be
        // plenty high for file descriptors.
        guard fileSize < 1024 * 1024 * 1024 else {
            stopTransfer()
            return owsFailDebug("Unexpectedly received a very large manifest \(fileSize)")
        }
        guard let data = try? Data(contentsOf: localURL) else {
            stopTransfer()
            return owsFailDebug("Failed to read manifest data")
        }
        guard let manifest = try? DeviceTransferProtoManifest(serializedData: data) else {
            stopTransfer()
            return owsFailDebug("Failed to parse manifest proto")
        }
        guard !DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            stopTransfer()
            return owsFailDebug("Ignoring incoming transfer to a registered device")
        }

        DeviceTransfer.Utils.resetTransferDirectory(createNewTransferDirectory: true)

        do {
            try OWSFileSystem.moveFilePath(
                localURL.path,
                toFilePath: URL(
                    fileURLWithPath: DeviceTransfer.Constants.manifestIdentifier,
                    relativeTo: DeviceTransfer.Constants.pendingTransferDirectory,
                ).path,
            )
        } catch {
            owsFailDebug("Failed to move manifest into place: \(error.shortDescription)")
            return
        }

        let progress = Progress(totalUnitCount: Int64(manifest.estimatedTotalSize))

        transferState = .incoming(
            oldDevicePeerId: peerId,
            manifest: manifest,
            receivedFileIds: [DeviceTransfer.Constants.manifestIdentifier],
            skippedFileIds: [],
            progress: progress,
        )

        DependenciesBridge.shared.db.write { tx in
            DependenciesBridge.shared.registrationStateChangeManager.setIsTransferInProgress(tx: tx)
        }

        notifyObservers { $0.deviceTransferServiceDidStartTransfer(progress: progress) }

        Task { @MainActor in
            self.throughputMonitor = ThroughputMonitor(progress: progress)
            throughputMonitor?.start()
        }

        // Check if the device has a newer version of the database than we understand

        guard manifest.grdbSchemaVersion <= GRDBSchemaMigrator.grdbSchemaVersionLatest else {
            return self.failTransfer(.unsupportedVersion, "Ignoring manifest with unsupported schema version")
        }

        // Check if there is enough space on disk to receive the transfer

        guard
            let freeSpaceInBytes = try? OWSFileSystem.freeSpaceInBytes(
                forPath: DeviceTransfer.Constants.pendingTransferDirectory,
            )
        else {
            return self.failTransfer(.assertion, "failed to calculate available disk space")
        }

        guard freeSpaceInBytes > manifest.estimatedTotalSize else {
            return self.failTransfer(.notEnoughSpace, "not enough free space to receive transfer")
        }
    }

    @MainActor
    func sendManifest(session: DeviceTransferSession) async throws {
        Logger.info("Sending manifest to new device.")

        guard case .outgoing(let newDevicePeerId, _, let manifest, _, _) = transferState else {
            throw OWSAssertionError("attempted to send manifest while no active outgoing transfer")
        }

        DeviceTransfer.Utils.resetTransferDirectory(createNewTransferDirectory: true)

        // We write the manifest to a temp file, since MCSession only allows sending "typed"
        // data when sending files, unless you do your own stream management.
        let manifestData = try manifest.serializedData()
        let manifestFileURL = URL(
            fileURLWithPath: DeviceTransfer.Constants.manifestIdentifier,
            relativeTo: DeviceTransfer.Constants.pendingTransferDirectory,
        )
        try manifestData.write(to: manifestFileURL, options: .atomic)

        defer {
            OWSFileSystem.deleteFileIfExists(manifestFileURL.path)
        }

        try await session.sendResource(
            url: manifestFileURL,
            name: DeviceTransfer.Constants.manifestIdentifier,
            to: newDevicePeerId,
            progressBlock: { _ in },
        )

        Logger.info("Successfully sent manifest to new device.")

        transferState = self.transferState.appendingFileId(DeviceTransfer.Constants.manifestIdentifier)
        throughputMonitor?.start()
    }

    func verifyTransferCompletedSuccessfully(receivedFileIds: [String], skippedFileIds: [String]) -> Bool {
        guard let manifest = DeviceTransfer.Utils.readManifestFromTransferDirectory() else {
            owsFailDebug("Missing manifest file")
            return false
        }

        // Check that there aren't any files that we were
        // expecting that are missing.
        for file in manifest.files {
            guard !skippedFileIds.contains(file.identifier) else { continue }

            guard receivedFileIds.contains(file.identifier) else {
                owsFailDebug("did not receive file \(file.identifier)")
                return false
            }
            guard
                OWSFileSystem.fileOrFolderExists(
                    atPath: URL(
                        fileURLWithPath: file.identifier,
                        relativeTo: DeviceTransfer.Constants.pendingTransferFilesDirectory,
                    ).path,
                )
            else {
                owsFailDebug("Missing file \(file.identifier)")
                return false
            }
        }

        // Check that the appropriate database files were received
        guard let database = manifest.database else {
            owsFailDebug("missing database proto")
            return false
        }

        guard database.key.count == GRDBKeyFetcher.Constants.kSQLCipherKeySpecLength else {
            owsFailDebug("incorrect database key length")
            return false
        }

        guard receivedFileIds.contains(DeviceTransfer.Constants.databaseIdentifier) else {
            owsFailDebug("did not receive database file")
            return false
        }

        guard
            OWSFileSystem.fileOrFolderExists(
                atPath: URL(
                    fileURLWithPath: DeviceTransfer.Constants.databaseIdentifier,
                    relativeTo: DeviceTransfer.Constants.pendingTransferFilesDirectory,
                ).path,
            )
        else {
            owsFailDebug("missing database file")
            return false
        }

        guard receivedFileIds.contains(DeviceTransfer.Constants.databaseWALIdentifier) else {
            owsFailDebug("did not receive database wal file")
            return false
        }

        guard
            OWSFileSystem.fileOrFolderExists(
                atPath: URL(
                    fileURLWithPath: DeviceTransfer.Constants.databaseWALIdentifier,
                    relativeTo: DeviceTransfer.Constants.pendingTransferFilesDirectory,
                ).path,
            )
        else {
            owsFailDebug("missing database wal file")
            return false
        }

        return true
    }

    enum TransferState {
        case idle
        case incoming(
            oldDevicePeerId: DeviceTransferPeerID,
            manifest: DeviceTransferProtoManifest,
            receivedFileIds: [String],
            skippedFileIds: [String],
            progress: Progress,
        )
        case outgoing(
            newDevicePeerId: DeviceTransferPeerID,
            newDeviceCertificateHash: Data,
            manifest: DeviceTransferProtoManifest,
            transferredFileIds: [String],
            progress: Progress,
        )

        func appendingFileId(_ fileId: String) -> TransferState {
            switch self {
            case .incoming(let oldDevicePeerId, let manifest, let receivedFileIds, let skippedFileIds, let progress):
                return .incoming(
                    oldDevicePeerId: oldDevicePeerId,
                    manifest: manifest,
                    receivedFileIds: receivedFileIds + [fileId],
                    skippedFileIds: skippedFileIds,
                    progress: progress,
                )
            case .outgoing(let newDevicePeerId, let newDeviceCertificateHash, let manifest, let transferredFileIds, let progress):
                return .outgoing(
                    newDevicePeerId: newDevicePeerId,
                    newDeviceCertificateHash: newDeviceCertificateHash,
                    manifest: manifest,
                    transferredFileIds: transferredFileIds + [fileId],
                    progress: progress,
                )
            case .idle:
                owsFailDebug("unexpectedly tried to append file while idle")
                return .idle
            }
        }

        func appendingSkippedFileId(_ fileId: String) -> TransferState {
            switch self {
            case .incoming(let oldDevicePeerId, let manifest, let receivedFileIds, let skippedFileIds, let progress):
                return .incoming(
                    oldDevicePeerId: oldDevicePeerId,
                    manifest: manifest,
                    receivedFileIds: receivedFileIds,
                    skippedFileIds: skippedFileIds + [fileId],
                    progress: progress,
                )
            case .outgoing(let newDevicePeerId, let newDeviceCertificateHash, let manifest, let transferredFileIds, let progress):
                owsFailDebug("unexpectedly tried to append a skipped file on outgoing")
                return .outgoing(
                    newDevicePeerId: newDevicePeerId,
                    newDeviceCertificateHash: newDeviceCertificateHash,
                    manifest: manifest,
                    transferredFileIds: transferredFileIds,
                    progress: progress,
                )
            case .idle:
                owsFailDebug("unexpectedly tried to append a skipped file while idle")
                return .idle
            }
        }
    }

    func parseTransferURL(_ url: URL) throws -> (peerId: DeviceTransferPeerID, certificateHash: Data) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItems = components.queryItems else {
            throw OWSAssertionError("Invalid url")
        }

        let queryItemsDictionary = [String: String](uniqueKeysWithValues: queryItems.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        guard
            let version = queryItemsDictionary[DeviceTransfer.UrlConstants.versionKey],
            Int(version) == DeviceTransfer.UrlConstants.currentTransferVersion
        else {
            throw DeviceTransfer.Error.unsupportedVersion
        }

        let currentMode: DeviceTransfer.Mode = DependenciesBridge.shared.tsAccountManager
            .registrationStateWithMaybeSneakyTransaction.isPrimaryDevice == true ? .primary : .linked

        guard
            let rawMode = queryItemsDictionary[DeviceTransfer.UrlConstants.transferModeKey],
            rawMode == currentMode.rawValue
        else {
            throw DeviceTransfer.Error.modeMismatch
        }

        guard
            let base64CertificateHash = queryItemsDictionary[DeviceTransfer.UrlConstants.certificateHashKey],
            let uriDecodedHash = base64CertificateHash.removingPercentEncoding,
            let certificateHash = Data(base64Encoded: uriDecodedHash)
        else {
            throw OWSAssertionError("failed to decode certificate hash")
        }

        guard
            let base64PeerId = queryItemsDictionary[DeviceTransfer.UrlConstants.peerIdKey],
            let uriDecodedPeerId = base64PeerId.removingPercentEncoding,
            let peerIdData = Data(base64Encoded: uriDecodedPeerId),
            let peerId = DeviceTransferPeerID(with: peerIdData)
        else {
            throw OWSAssertionError("failed to decode MCPeerId")
        }

        return (peerId, certificateHash)
    }
}

#if TESTABLE_BUILD

class DeviceTransferServiceMock: DeviceTransferServiceProtocol {
    func startAcceptingTransfersFromOldDevices(mode: Signal.DeviceTransfer.Mode) throws -> URL {
        return URL(string: "https://example.com")!
    }

    func addObserver(_ observer: any DeviceTransferServiceObserver) { }

    func removeObserver(_ observer: any DeviceTransferServiceObserver) { }

    func stopAcceptingTransfersFromOldDevices() { }

    func cancelTransferFromOldDevice() { }
}

#endif
