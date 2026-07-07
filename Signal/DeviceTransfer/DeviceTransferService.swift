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
    func deviceTransferServiceDidEndTransfer(error: DeviceTransferService.Error?)

    func deviceTransferServiceDidRequestAppRelaunch()
}

protocol DeviceTransferServiceProtocol {
    func startAcceptingTransfersFromOldDevices(mode: DeviceTransferService.TransferMode) throws -> URL
    func addObserver(_ observer: DeviceTransferServiceObserver)
    func removeObserver(_ observer: DeviceTransferServiceObserver)
    func stopAcceptingTransfersFromOldDevices()
    func cancelTransferFromOldDevice()
}

///
/// The following service is used to facilitate users in transferring their account from
/// an old device (OD) to a new device (ND) using MultipeerConnectivity. The general steps
/// of the process follow the following flow:
///
/// 1) As you begin setting up a new device (ND), you are asked if you want to transfer data
///    from an old device (OD). This happens *after* the SMS code and reg lock pin are provided,
///    but (importantly) before the service replaces your old account. Accounts are identified
///    by the service as being eligible for transfer by setting the "transfer" capability.
/// 2) In order to notify potential ODs on the network, the ND will begin advertising a
///    “transfer service” using Bonjour. Nearby ODs will be readily browsing for this service,
///     but not establishing any connections until the user takes action. The ND will actively
///     attempt to connect to any other “transfer service” it finds. MC will under-the-hood
///     determine whether it’s best to use peer-to-peer Wi-Fi, Bluetooth, or infrastructure Wi-Fi
/// 3) In order to prepare for a session from the OD, the ND will generate an RSA 2048 private
///    key and self-signed public certificate (used for DTLS). It will then present a QR code
///    that contains:
///      a. The transfer version, so we can eliminate the need for a lot of backwards compatibility
///      b. The MC Peer identifier (an opaque blob of data that represents the ND, that the
///         OD can use to determine what device to connect to)
///      c. A sha256 hash of the public certificate, so we can verify we're connected to
///         the appropriate ND
///      d. A mode flag indicating whether we're expecting to transfer from a primary device
///         or a linked device.
/// 4) On your OD, you will accept the prompt in the Signal app to enter transfer mode.
///    A QR scanner will be presented to you.
/// 5) When the OD scans the QR code presented on the ND, it will:
///      a. Attempt to open an encrypted (DTLS) session with the specified MC session identifier
///      b. Validate the certificate for the connection exactly matches the certificate scanned from the ND
///      c. Start locally behaving as if it is unregistered, without actually unregistering from the
///         service (to prevent two devices registered with the same number)
///      d. Send a manifest to the ND that outlines a list of all the files it should expect, including:
///          i. The SQLCipher DB key
///          ii. The sqlite database file (with no additional encryption beyond SQLCipher)
///          iii. All attachment files stored on the device
///          iv. The user preference dictionary (user defaults)
///      e. Start transferring all the files to the new device
///  6) When all data has been transferred successfully,
///      a. the OD will:
///          i. Flag that it was transferred, it will now remain unregistered regardless of what
///             happens on the ND.
///          ii. Send a "done" message to the ND, to notify that it thinks it's done
///          iii. Wait for a "done" message from the ND – if received, all local data will be deleted.
///      b. the ND will, upon receipt of the "done" message:
///          i. Verify all data that was expected to be received was received
///          ii. Mark itself as pending restore
///          iii. Notify the ND that it is "done" and it's safe to self-destruct
///          iv. Move all the received files into place, set the new database key, etc.
///          v. Hot-swap the new database into place and present the conversation list
///
class DeviceTransferService:
    DeviceTransferServiceProtocol,
    DeviceTransferSessionDelegate,
    DeviceTransferServiceBrowserDelegate
{

    static let appSharedDataDirectory = URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath())
    static let pendingTransferDirectory = URL(fileURLWithPath: "transfer", isDirectory: true, relativeTo: appSharedDataDirectory)
    static let pendingTransferFilesDirectory = URL(fileURLWithPath: "files", isDirectory: true, relativeTo: pendingTransferDirectory)

    static let manifestIdentifier = "manifest"
    static let databaseIdentifier = "database"
    static let databaseWALIdentifier = "database-wal"

    static let missingFileData = Data("Missing File".utf8)
    static let missingFileHash = Data(SHA256.hash(data: missingFileData))

    private let serialQueue = DispatchQueue(label: "org.signal.device-transfer")
    private var _transferState: TransferState = .idle
    var transferState: TransferState {
        get { serialQueue.sync { _transferState } }
        set { serialQueue.sync { _transferState = newValue } }
    }

    private let sleepBlockObject = DeviceSleepBlockObject(blockReason: "device transfer")

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

    init(appReadiness: AppReadiness, deviceSleepManager: DeviceSleepManagerImpl, keychainStorage: any KeychainStorage) {
        self.appReadiness = appReadiness
        self.deviceSleepManager = deviceSleepManager
        self.keychainStorage = keychainStorage

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: .OWSApplicationDidEnterBackground,
            object: nil,
        )
    }

    // MARK: - New Device

    func startAcceptingTransfersFromOldDevices(mode: TransferMode) throws -> URL {
        Task {
            await self.deviceSleepManager.addBlock(blockObject: sleepBlockObject)
        }

        var session = try newDeviceServiceAdvertiser.startAdvertising()
        session.delegate = self

        return try DeviceTransferService.urlForTransfer(session: session, mode: mode)
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

        Task {
            await self.deviceSleepManager.addBlock(blockObject: sleepBlockObject)
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

    func failTransfer(_ error: Error, _ reason: String) {
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

        Task {
            await self.deviceSleepManager.removeBlock(blockObject: sleepBlockObject)
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

        stopThroughputCalculation()
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
        if databaseFile.identifier == databaseIdentifier {
            newFileName = Self.dbCopyFilename
            newFileExtension = ".sqlite"
        } else if databaseFile.identifier == databaseWALIdentifier {
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
            relativeTo: DeviceTransferService.appSharedDataDirectory,
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

    static let doneMessage = Data("Transfer Complete".utf8)
    func sendDoneMessage(to peerId: DeviceTransferPeerID, session: DeviceTransferSession) throws {
        Logger.info("Sending done message")
        try session.send(DeviceTransferService.doneMessage, toPeers: [peerId], with: .reliable)
    }

    static let backgroundAppMessage = Data("App backgrounded".utf8)
    func sendBackgroundAppMessage(to peerId: DeviceTransferPeerID, session: DeviceTransferSession) throws {
        Logger.info("Sending backgrounded message")
        try session.send(DeviceTransferService.backgroundAppMessage, toPeers: [peerId], with: .unreliable)
    }

    // MARK: - Throughput

    private var previouslyCompletedBytes: Double = 0
    private var lastWholeNumberProgress = 0
    private var throughputTimer: Timer?
    func startThroughputCalculation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startThroughputCalculation() }
            return
        }

        stopThroughputCalculation()

        guard
            let progress: Progress = {
                switch transferState {
                case .incoming(_, _, _, _, let progress):
                    return progress
                case .outgoing(_, _, _, _, let progress):
                    return progress
                case .idle:
                    owsFailDebug("Can't start throughput calculation while idle")
                    return nil
                }
            }()
        else {
            return owsFailDebug("Can't start throughput calculations without progress")
        }

        previouslyCompletedBytes = Double(progress.totalUnitCount) * progress.fractionCompleted

        throughputTimer = WeakTimer.scheduledTimer(timeInterval: 1, target: self, userInfo: nil, repeats: true) { _ in
            let completedBytes = Double(progress.totalUnitCount) * progress.fractionCompleted
            let bytesOverLastSecond = completedBytes - self.previouslyCompletedBytes
            let remainingBytes = Double(progress.totalUnitCount) - completedBytes
            self.previouslyCompletedBytes = completedBytes

            if let averageThroughput = progress.throughput {
                // Give more weight to the existing average than the new value
                // to "smooth" changes in throughput and estimated time remaining.
                let newAverageThroughput = 0.2 * Double(bytesOverLastSecond) + 0.8 * Double(averageThroughput)
                progress.throughput = Int(newAverageThroughput)
                progress.estimatedTimeRemaining = remainingBytes / newAverageThroughput
            } else {
                progress.throughput = Int(bytesOverLastSecond)
                progress.estimatedTimeRemaining = remainingBytes / TimeInterval(bytesOverLastSecond)
            }

            self.logProgress(progress, remainingBytes: remainingBytes)
        }
        throughputTimer?.fire()
    }

    private func logProgress(_ progress: Progress, remainingBytes: Double) {
        let currentWholeNumberProgress = Int(progress.fractionCompleted * 100)
        let percentChange = currentWholeNumberProgress - lastWholeNumberProgress

        defer { lastWholeNumberProgress = currentWholeNumberProgress }

        // Determine how frequently to log progress updates. If in verbose mode, we log
        // every 1%. Otherwise, every 10%.
        guard percentChange >= (DebugFlags.deviceTransferVerboseProgressLogging ? 1 : 10) else { return }

        var progressLog = String(format: "Transfer progress %d%%", currentWholeNumberProgress)

        var remainingNumber = remainingBytes
        var remainingUnits = "B"
        if remainingNumber / 1024 >= 1 {
            remainingNumber /= 1024
            remainingUnits = "KiB"
        }
        if remainingNumber / 1024 >= 1 {
            remainingNumber /= 1024
            remainingUnits = "MiB"
        }
        if remainingNumber / 1024 >= 1 {
            remainingNumber /= 1024
            remainingUnits = "GiB"
        }

        progressLog += String(format: " / %0.2f %@ remaining", remainingNumber, remainingUnits)

        if let throughput = progress.throughput {
            var transferSpeed = Double(throughput) / 1024
            var transferUnits = "KiB/s"
            if transferSpeed / 1024 >= 1 {
                transferSpeed /= 1024
                transferUnits = "MiB/s"
            }

            progressLog += String(format: " / %0.2f %@", transferSpeed, transferUnits)
        }

        if let estimatedTime = progress.estimatedTimeRemaining, estimatedTime.isFinite {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 2
            formatter.includesApproximationPhrase = true
            formatter.includesTimeRemainingPhrase = true

            let formattedString = formatter.string(from: estimatedTime)!

            progressLog += " / \(formattedString)"
        }

        Logger.info(progressLog)
    }

    func stopThroughputCalculation() {
        throughputTimer?.invalidate()
        throughputTimer = nil
        previouslyCompletedBytes = 0
        lastWholeNumberProgress = 0
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
                    guard !transferredFiles.contains(DeviceTransferService.manifestIdentifier) else { return }

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
            case DeviceTransferService.backgroundAppMessage:
                return failTransfer(.backgroundedDevice, "Received terminate message")
            case DeviceTransferService.doneMessage:
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
            case DeviceTransferService.backgroundAppMessage:
                return failTransfer(.backgroundedDevice, "Received backgrounded message")
            case DeviceTransferService.doneMessage:
                break
            default:
                return failTransfer(.assertion, "Received unexpected data")
            }

            stopThroughputCalculation()

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
            let startPhase = RestorationPhase.start
            Logger.info("Setting restoration phase to: \(startPhase)")
            rawRestorationPhase = startPhase.rawValue

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
                try restoreTransferredData()
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
            guard resourceName == DeviceTransferService.manifestIdentifier else {
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
                    case DeviceTransferService.databaseIdentifier:
                        return manifest.database?.database
                    case DeviceTransferService.databaseWALIdentifier:
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
            guard resourceName == DeviceTransferService.manifestIdentifier else {
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
                    case DeviceTransferService.databaseIdentifier:
                        return manifest.database?.database
                    case DeviceTransferService.databaseWALIdentifier:
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
                OWSFileSystem.ensureDirectoryExists(DeviceTransferService.pendingTransferFilesDirectory.path)

                guard let computedHash = try? Cryptography.computeSHA256DigestOfFile(at: localURL) else {
                    return failTransfer(.assertion, "Failed to compute hash for \(file.identifier)")
                }

                guard computedHash.hexadecimalString == fileHash else {
                    return failTransfer(.assertion, "Received file with incorrect hash \(file.identifier)")
                }

                guard computedHash != DeviceTransferService.missingFileHash else {
                    Logger.warn("Received notification of missing file: \(file.identifier), skipping.")
                    transferState = transferState.appendingSkippedFileId(file.identifier)
                    return
                }

                do {
                    try OWSFileSystem.moveFilePath(
                        localURL.path,
                        toFilePath: URL(
                            fileURLWithPath: file.identifier,
                            relativeTo: DeviceTransferService.pendingTransferFilesDirectory,
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
        didReceiveCertificate certificates: [Any]?,
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
                    identifier: DeviceTransferService.databaseIdentifier,
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
                    identifier: DeviceTransferService.databaseWALIdentifier,
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
            let url = URL(fileURLWithPath: folder, relativeTo: DeviceTransferService.appSharedDataDirectory)
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

        var path = path.replacingOccurrences(of: DeviceTransferService.appSharedDataDirectory.path, with: "")
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

        resetTransferDirectory(createNewTransferDirectory: true)

        do {
            try OWSFileSystem.moveFilePath(
                localURL.path,
                toFilePath: URL(
                    fileURLWithPath: DeviceTransferService.manifestIdentifier,
                    relativeTo: DeviceTransferService.pendingTransferDirectory,
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
            receivedFileIds: [DeviceTransferService.manifestIdentifier],
            skippedFileIds: [],
            progress: progress,
        )

        DependenciesBridge.shared.db.write { tx in
            DependenciesBridge.shared.registrationStateChangeManager.setIsTransferInProgress(tx: tx)
        }

        notifyObservers { $0.deviceTransferServiceDidStartTransfer(progress: progress) }

        startThroughputCalculation()

        // Check if the device has a newer version of the database than we understand

        guard manifest.grdbSchemaVersion <= GRDBSchemaMigrator.grdbSchemaVersionLatest else {
            return self.failTransfer(.unsupportedVersion, "Ignoring manifest with unsupported schema version")
        }

        // Check if there is enough space on disk to receive the transfer

        guard
            let freeSpaceInBytes = try? OWSFileSystem.freeSpaceInBytes(
                forPath: DeviceTransferService.pendingTransferDirectory,
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

        resetTransferDirectory(createNewTransferDirectory: true)

        // We write the manifest to a temp file, since MCSession only allows sending "typed"
        // data when sending files, unless you do your own stream management.
        let manifestData = try manifest.serializedData()
        let manifestFileURL = URL(
            fileURLWithPath: DeviceTransferService.manifestIdentifier,
            relativeTo: DeviceTransferService.pendingTransferDirectory,
        )
        try manifestData.write(to: manifestFileURL, options: .atomic)

        defer {
            OWSFileSystem.deleteFileIfExists(manifestFileURL.path)
        }

        try await session.sendResource(
            url: manifestFileURL,
            name: DeviceTransferService.manifestIdentifier,
            to: newDevicePeerId,
            progressBlock: { _ in },
        )

        Logger.info("Successfully sent manifest to new device.")

        transferState = self.transferState.appendingFileId(DeviceTransferService.manifestIdentifier)
        startThroughputCalculation()
    }

    func readManifestFromTransferDirectory() -> DeviceTransferProtoManifest? {
        let manifestPath = URL(
            fileURLWithPath: DeviceTransferService.manifestIdentifier,
            relativeTo: DeviceTransferService.pendingTransferDirectory,
        ).path
        guard OWSFileSystem.fileOrFolderExists(atPath: manifestPath) else { return nil }
        guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)) else { return nil }
        return try? DeviceTransferProtoManifest(serializedData: manifestData)
    }

    private static let hasBeenRestoredKey = "DeviceTransferHasBeenRestored"
    var hasBeenRestored: Bool {
        get { CurrentAppContext().appUserDefaults().bool(forKey: DeviceTransferService.hasBeenRestoredKey) }
        set { CurrentAppContext().appUserDefaults().set(newValue, forKey: DeviceTransferService.hasBeenRestoredKey) }
    }

    private static let restorePhaseKey = "DeviceTransferRestorationPhase"
    var rawRestorationPhase: Int {
        get { CurrentAppContext().appUserDefaults().integer(forKey: DeviceTransferService.restorePhaseKey) }
        set { CurrentAppContext().appUserDefaults().set(newValue, forKey: DeviceTransferService.restorePhaseKey) }
    }

    var restorationPhase: RestorationPhase {
        get throws {
            try RestorationPhase(rawValue: rawRestorationPhase) ?? {
                throw OWSAssertionError("Invalid raw value: \(rawRestorationPhase)")
            }()
        }
    }

    func verifyTransferCompletedSuccessfully(receivedFileIds: [String], skippedFileIds: [String]) -> Bool {
        guard let manifest = readManifestFromTransferDirectory() else {
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
                        relativeTo: DeviceTransferService.pendingTransferFilesDirectory,
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

        guard receivedFileIds.contains(DeviceTransferService.databaseIdentifier) else {
            owsFailDebug("did not receive database file")
            return false
        }

        guard
            OWSFileSystem.fileOrFolderExists(
                atPath: URL(
                    fileURLWithPath: DeviceTransferService.databaseIdentifier,
                    relativeTo: DeviceTransferService.pendingTransferFilesDirectory,
                ).path,
            )
        else {
            owsFailDebug("missing database file")
            return false
        }

        guard receivedFileIds.contains(DeviceTransferService.databaseWALIdentifier) else {
            owsFailDebug("did not receive database wal file")
            return false
        }

        guard
            OWSFileSystem.fileOrFolderExists(
                atPath: URL(
                    fileURLWithPath: DeviceTransferService.databaseWALIdentifier,
                    relativeTo: DeviceTransferService.pendingTransferFilesDirectory,
                ).path,
            )
        else {
            owsFailDebug("missing database wal file")
            return false
        }

        return true
    }

    func resetTransferDirectory(createNewTransferDirectory: Bool) {
        do {
            try FileManager.default.removeItem(atPath: DeviceTransferService.pendingTransferDirectory.path)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile, POSIXError.ENOENT {
            // it doesn't exist -- this is fine
        } catch {
            owsFailDebug("Failed to delete existing transfer directory \(error)")
        }
        if createNewTransferDirectory {
            OWSFileSystem.ensureDirectoryExists(DeviceTransferService.pendingTransferDirectory.path)
        }

        // If we had a pending restore, we no longer do.
        switch try? restorationPhase {
        case .noCurrentRestoration, .cleanup: break
        default: rawRestorationPhase = RestorationPhase.noCurrentRestoration.rawValue
        }
    }

    private func move(pendingFilePath: String, to newFilePath: String) throws {
        OWSFileSystem.ensureDirectoryExists((newFilePath as NSString).deletingLastPathComponent)
        try OWSFileSystem.moveFilePath(pendingFilePath, toFilePath: newFilePath)
    }

    func launchCleanup() -> Bool {
        Logger.info("hasBeenRestored: \(hasBeenRestored)")

        let success: Bool
        if hasIncompleteRestoration {
            do {
                try restoreTransferredData()
                success = true
            } catch {
                owsFailDebug("Failed to finish restoration: \(error)")
                success = false
            }
        } else {
            success = true
        }
        if success {
            finalizeRestorationIfNecessary()
        }
        return success
    }
}

extension DeviceTransferService {

    enum RestorationPhase: Int {
        // Start/Complete: Nothing to do.
        case noCurrentRestoration = 0

        // Performed by `restoreTransferredData()`
        case start
        case updateUserDefaults
        case moveManifestFiles
        case allocateNewDatabaseDirectory
        case moveDatabaseFiles
        case updateDatabase

        // This state represents that there's some one-time cleanup that's left to be done
        // Restoration is complete, but every time the app launches `finalizeRestorationIfNecessary`
        // will run and transition to `noCurrentRestoration` once successful
        case cleanup

        var next: RestorationPhase {
            RestorationPhase(rawValue: rawValue + 1) ?? .noCurrentRestoration
        }
    }

    var hasIncompleteRestoration: Bool { rawRestorationPhase > 0 }
    func restoreTransferredData() throws {
        do {
            let manifest: DeviceTransferProtoManifest? = readManifestFromTransferDirectory()

            // Run through the restoration steps. The deal here is:
            // - The phase we're currently on has not been completed yet
            // - Each phase must be idempotent and capable of handling arbitrary interruption (i.e. crashes)
            // - If a phase completes without error, it should be durable
            // - We return once we've hit `noCurrentRestoration` or `cleanup`
            var currentPhase = try restorationPhase
            while currentPhase != .noCurrentRestoration, currentPhase != .cleanup {
                Logger.info("Performing restoration phase: \(currentPhase)")
                try performRestorationPhase(currentPhase, manifest: manifest)
                Logger.info("Completed restoration phase: \(currentPhase)")

                currentPhase = currentPhase.next
                rawRestorationPhase = currentPhase.rawValue
            }
        } catch {
            owsFailDebug("Hit error during restoration phase \(rawRestorationPhase): \(error)")
            throw error
        }
    }

    private func performRestorationPhase(_ phase: RestorationPhase, manifest: DeviceTransferProtoManifest?) throws {
        switch phase {
        case .noCurrentRestoration, .cleanup:
            owsFailDebug("Unexpected state")
        case .start:
            // No-op, having a start case jut makes the logs look nice
            break
        case .updateUserDefaults:
            try updateUserDefaults(manifest: manifest)
        case .moveManifestFiles:
            try moveManifestFiles(manifest: manifest)
        case .allocateNewDatabaseDirectory:
            allocateNewDatabaseDirectory()
        case .moveDatabaseFiles:
            try moveDatabaseFiles(manifest: manifest)
        case .updateDatabase:
            try updateCurrentDatabase(manifest: manifest)
            // At this point, we've restored all of the data we need. Just some bits of cleanup left.
            hasBeenRestored = true
        }
    }

    private func updateUserDefaults(manifest: DeviceTransferProtoManifest?) throws {
        guard let manifest else {
            throw OWSAssertionError("No manifest available")
        }

        let possibleUserDefaultClasses = [
            NSData.self,
            NSString.self,
            NSNumber.self,
            NSDate.self,
            NSArray.self,
            NSDictionary.self,
        ]
        // TODO: We should codify how we want to use standardDefaults. Either we should
        // get rid of them, or expand them to support all of our extensions
        for userDefault in manifest.standardDefaults {
            guard let unarchivedValue = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: possibleUserDefaultClasses, from: userDefault.encodedValue) else {
                owsFailDebug("Failed to unarchive value for key \(userDefault.key)")
                continue
            }

            UserDefaults.standard.set(unarchivedValue, forKey: userDefault.key)
        }

        // TODO: Do we want to transfer all of our app defaults?
        for userDefault in manifest.appDefaults {
            guard
                ![
                    GRDBDatabaseStorageAdapter.DirectoryMode.primaryFolderNameKey,
                    GRDBDatabaseStorageAdapter.DirectoryMode.transferFolderNameKey,
                    DeviceTransferService.hasBeenRestoredKey,
                ].contains(userDefault.key) else { continue }

            guard let unarchivedValue = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: possibleUserDefaultClasses, from: userDefault.encodedValue) else {
                owsFailDebug("Failed to unarchive value for key \(userDefault.key)")
                continue
            }
            CurrentAppContext().appUserDefaults().set(unarchivedValue, forKey: userDefault.key)
        }
    }

    private func moveManifestFiles(manifest: DeviceTransferProtoManifest?) throws {
        guard let manifest else {
            throw OWSAssertionError("No manifest available")
        }
        let sourceDir = DeviceTransferService.pendingTransferFilesDirectory
        let destDir = DeviceTransferService.appSharedDataDirectory

        try manifest.files.forEach { file in
            let sourceUrl = URL(fileURLWithPath: file.identifier, relativeTo: sourceDir)
            let destUrl = URL(fileURLWithPath: file.relativePath, relativeTo: destDir)

            do {
                try move(pendingFilePath: sourceUrl.path, to: destUrl.path)
            } catch CocoaError.fileWriteFileExists {
                Logger.info("Skipping restoration of file that was already restored: \(file.identifier)")
            } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile, POSIXError.ENOENT {
                // We sometimes don't receive a file because it goes missing on the old
                // device between when we generate the manifest and when we perform the
                // restoration. Our verification process ensures that the only files that
                // could be missing in this way are non-essential files. It's better to
                // let the user continue than to lock them out of the app in this state.
                Logger.info("Skipping restoration of missing file: \(file.identifier)")
            } catch {
                throw OWSAssertionError("Failed to move file \(file.identifier)")
            }
        }
    }

    // We create the directory but do not touch anything about it until this phase has committed
    private func allocateNewDatabaseDirectory() {
        GRDBDatabaseStorageAdapter.createNewTransferDirectory()
    }

    private func moveDatabaseFiles(manifest: DeviceTransferProtoManifest?) throws {
        guard let database = manifest?.database else {
            throw OWSAssertionError("No manifest database available")
        }
        let sourceDir = DeviceTransferService.pendingTransferFilesDirectory
        let databaseSourceFiles = [database.database, database.wal]

        try databaseSourceFiles.forEach { file in
            let sourceUrl = URL(fileURLWithPath: file.identifier, relativeTo: sourceDir)
            let destUrl: URL
            switch file.identifier {
            case DeviceTransferService.databaseIdentifier:
                destUrl = GRDBDatabaseStorageAdapter.databaseFileUrl(directoryMode: .transfer)
            case DeviceTransferService.databaseWALIdentifier:
                destUrl = GRDBDatabaseStorageAdapter.databaseWalUrl(directoryMode: .transfer)
            default:
                throw OWSAssertionError("Unknown file identifier")
            }

            do {
                try move(pendingFilePath: sourceUrl.path, to: destUrl.path)
            } catch CocoaError.fileWriteFileExists {
                Logger.info("Skipping restoration of database file that was already restored: \(file.identifier)")
            } catch {
                throw OWSAssertionError("Failed to move file \(file.identifier); \(error.shortDescription)")
            }
        }
    }

    private func updateCurrentDatabase(manifest: DeviceTransferProtoManifest?) throws {
        guard let database = manifest?.database else {
            throw OWSAssertionError("No manifest database available")
        }

        try GRDBKeyFetcher(keychainStorage: keychainStorage).store(data: database.key)
        GRDBDatabaseStorageAdapter.promoteTransferDirectoryToPrimary()
    }

    @discardableResult
    func finalizeRestorationIfNecessary() -> Guarantee<Void> {
        resetTransferDirectory(createNewTransferDirectory: false)

        let (promise, future) = Guarantee<Void>.pending()
        appReadiness.runNowOrWhenAppDidBecomeReadySync {
            DependenciesBridge.shared.db.write { tx in
                DependenciesBridge.shared.registrationStateChangeManager.setIsTransferComplete(
                    sendStateUpdateNotification: true,
                    tx: tx,
                )
            }

            // Consult both the modern and legacy restoration flag
            let currentPhase = (try? self.restorationPhase) ?? .noCurrentRestoration
            if currentPhase == .cleanup {
                Logger.info("Performing one-time post-restore cleanup...")
                GRDBDatabaseStorageAdapter.removeOrphanedGRDBDirectories()
                self.rawRestorationPhase = RestorationPhase.noCurrentRestoration.rawValue
                Logger.info("Done!")
            }

            future.resolve()
        }
        return promise
    }

    enum Error: Swift.Error {
        case assertion
        case cancel
        case backgroundedDevice
        case certificateMismatch
        case modeMismatch
        case notEnoughSpace
        case unsupportedVersion
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

    enum TransferMode: String {
        case linked
        case primary
    }

    private static let currentTransferVersion = 1

    private static let versionKey = "version"
    private static let peerIdKey = "peerId"
    private static let certificateHashKey = "certificateHash"
    private static let transferModeKey = "transferMode"

    private enum Constants {
        static let transferHost = "transfer"
    }

    static func urlForTransfer(
        session: DeviceTransferSession,
        mode: TransferMode,
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = UrlOpener.Constants.sgnlPrefix
        components.host = Constants.transferHost

        guard let base64CertificateHash = try session.identity.computeCertificateHash().base64EncodedString().encodeURIComponent else {
            throw OWSAssertionError("failed to get base64 certificate hash")
        }

        guard let base64PeerId = try? session.peerId.encoded().base64EncodedString().encodeURIComponent else {
            throw OWSAssertionError("failed to get base64 peerId")
        }

        let queryItems = [
            DeviceTransferService.versionKey: String(DeviceTransferService.currentTransferVersion),
            DeviceTransferService.transferModeKey: mode.rawValue,
            DeviceTransferService.certificateHashKey: base64CertificateHash,
            DeviceTransferService.peerIdKey: base64PeerId,
        ]

        components.queryItems = queryItems.map { URLQueryItem(name: $0.key, value: $0.value) }

        return components.url!
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
            let version = queryItemsDictionary[DeviceTransferService.versionKey],
            Int(version) == DeviceTransferService.currentTransferVersion
        else {
            throw Error.unsupportedVersion
        }

        let currentMode: TransferMode = DependenciesBridge.shared.tsAccountManager
            .registrationStateWithMaybeSneakyTransaction.isPrimaryDevice == true ? .primary : .linked

        guard
            let rawMode = queryItemsDictionary[DeviceTransferService.transferModeKey],
            rawMode == currentMode.rawValue
        else {
            throw Error.modeMismatch
        }

        guard
            let base64CertificateHash = queryItemsDictionary[DeviceTransferService.certificateHashKey],
            let uriDecodedHash = base64CertificateHash.removingPercentEncoding,
            let certificateHash = Data(base64Encoded: uriDecodedHash)
        else {
            throw OWSAssertionError("failed to decode certificate hash")
        }

        guard
            let base64PeerId = queryItemsDictionary[DeviceTransferService.peerIdKey],
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
    func startAcceptingTransfersFromOldDevices(mode: Signal.DeviceTransferService.TransferMode) throws -> URL {
        return URL(string: "https://example.com")!
    }

    func addObserver(_ observer: any DeviceTransferServiceObserver) { }

    func removeObserver(_ observer: any DeviceTransferServiceObserver) { }

    func stopAcceptingTransfersFromOldDevices() { }

    func cancelTransferFromOldDevice() { }
}

#endif
