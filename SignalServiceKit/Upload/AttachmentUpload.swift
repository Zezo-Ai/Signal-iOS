//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import QuartzCore

extension Upload.Constants {
    fileprivate static let uploadMaxRetries = 8
    fileprivate static let maxUploadProgressRetries = 2
}

public enum AttachmentUpload {

    // MARK: - Upload Entrypoint

    /// The main entry point into the CDN2/CDN3 upload flow.
    /// This method is responsible for prepping the source data and its metadata.
    /// From this point forward,  the upload doesn't have any knowledge of the source (attachment, backup, image, etc)
    public static func start<Metadata: UploadMetadata>(
        attempt: Upload.Attempt<Metadata>,
        dateProvider: @escaping DateProvider,
        sleepTimer: Upload.Shims.SleepTimer,
        progress: OWSProgressSink?,
    ) async throws -> Upload.Result<Metadata> {
        try Task.checkCancellation()

        let progressSource = progress?.addSource(
            withLabel: "upload",
            unitCount: UInt64(attempt.encryptedDataLength),
        )

        return try await attemptUpload(
            attempt: attempt,
            dateProvider: dateProvider,
            sleepTimer: sleepTimer,
            progress: progressSource,
        )
    }

    /// The retriable parts of the upload.
    /// 1. Create upload endpoint
    /// 2. Get the target URL from the endpoint
    /// 3. Initate the upload via the endpoint
    ///
    /// - Parameters:
    ///   - localMetadata: The metadata and URL path for the local upload data
    ///   will create a new request and fetch a new form.
    ///   - progressBlock: Callback notified up upload progress.
    /// - returns: `Upload.Result` reflecting the metadata of the final upload result.
    ///
    private static func attemptUpload<Metadata: UploadMetadata>(
        attempt: Upload.Attempt<Metadata>,
        dateProvider: @escaping DateProvider,
        sleepTimer: Upload.Shims.SleepTimer,
        progress: OWSProgressSource?,
    ) async throws -> Upload.Result<Metadata> {
        attempt.logger.info("Begin upload. (CDN\(attempt.cdnNumber)) [\(attempt.encryptedDataLength) bytes]")
        try await performResumableUpload(
            attempt: attempt,
            sleepTimer: sleepTimer,
            failureCount: 0,
            progress: progress,
        )
        progress?.complete()
        return Upload.Result(
            cdnKey: attempt.cdnKey,
            cdnNumber: attempt.cdnNumber,
            localUploadMetadata: attempt.localMetadata,
            beginTimestamp: attempt.beginTimestamp,
            finishTimestamp: dateProvider().ows_millisecondsSince1970,
        )
    }

    /// Consult the UploadEndpoint to determine how much has already been uploaded.
    private static func getResumableUploadProgress<Metadata: UploadMetadata>(forAttempt attempt: Upload.Attempt<Metadata>) async throws -> Upload.ResumeProgress {
        return try await Retry.performWithBackoff(
            maxAttempts: Upload.Constants.maxUploadProgressRetries + 1,
            isRetryable: { $0.isNetworkFailureOrTimeout },
            block: {
                attempt.logger.info("fetching resumable progress")
                return try await attempt.endpoint.getResumableUploadProgress(attempt: attempt)
            },
        )
    }

    /// Upload the file using the endpoint and report progress
    private static func performResumableUpload<Metadata: UploadMetadata>(
        attempt: Upload.Attempt<Metadata>,
        sleepTimer: Upload.Shims.SleepTimer,
        failureCount: Int,
        priorUploadProgress: Upload.ResumeProgress? = nil,
        progress: OWSProgressSource?,
    ) async throws {
        guard failureCount < Upload.Constants.uploadMaxRetries else {
            throw Upload.Error.uploadFailure(recovery: .noMoreRetries)
        }
        let startTime = CACurrentMediaTime()

        let totalDataLength = UInt64(safeCast: attempt.encryptedDataLength)
        let bytesAlreadyUploaded: UInt64

        // Only check remote upload progress if we think progress was made locally
        if attempt.isResumedUpload || failureCount > 0 {
            let uploadProgress: Upload.ResumeProgress
            if let priorUploadProgress {
                uploadProgress = priorUploadProgress
            } else {
                uploadProgress = try await getResumableUploadProgress(forAttempt: attempt)
            }
            switch uploadProgress {
            case .complete:
                attempt.logger.info("Complete upload reported by endpoint.")
                return
            case .uploaded(let updatedBytesAlreadUploaded):
                attempt.logger.info("Endpoint reported \(updatedBytesAlreadUploaded)/\(attempt.encryptedDataLength) uploaded.")
                bytesAlreadyUploaded = updatedBytesAlreadUploaded
                if bytesAlreadyUploaded == totalDataLength {
                    attempt.logger.info("Complete upload reported by endpoint.")
                    return
                } else if bytesAlreadyUploaded > totalDataLength {
                    attempt.logger.warn("Endpoint reported upload size larger than local size. Marking as failed")
                    throw Upload.Error.uploadFailure(recovery: .restart(.afterBackoff))
                }
            case .restart:
                attempt.logger.warn("Error with fetching progress. Restart upload.")
                throw Upload.Error.uploadFailure(recovery: .restart(.afterBackoff))
            }
        } else {
            bytesAlreadyUploaded = 0
        }

        // We might have made progress that wasn't reported; report it now.
        var newBytesUploaded = bytesAlreadyUploaded
        progress?.incrementCompletedUnitCount(to: bytesAlreadyUploaded)

        func downloadTimeLogString(_ bytesUploaded: UInt64) -> String {
            let totalTime = CACurrentMediaTime() - startTime
            guard totalTime > 0 else { return "" }

            let bytesDownloaded = bytesUploaded - bytesAlreadyUploaded
            let rate = Double(bytesDownloaded / 1024) / totalTime
            let timeMessage = String(format: "%lld bytes in %.2fs", bytesDownloaded, totalTime)

            if bytesDownloaded > 0 {
                return timeMessage + String(format: " (%.2f KiB/s)", rate)
            } else {
                return timeMessage
            }
        }

        do {
            try await attempt.endpoint.performUpload(
                startPoint: bytesAlreadyUploaded,
                attempt: attempt,
                progressBlock: { currentByteCount, totalByteCount in
                    newBytesUploaded = max(newBytesUploaded, UInt64(currentByteCount))
                    progress?.incrementCompletedUnitCount(to: UInt64(currentByteCount))
                },
            )
            attempt.logger.info("Attachment uploaded successfully. \(bytesAlreadyUploaded) -> \(newBytesUploaded) (\(downloadTimeLogString(newBytesUploaded))")
        } catch {
            if let statusCode = error.httpStatusCode {
                attempt.logger.warn("Encountered error during upload. (code=\(statusCode)")
            } else {
                attempt.logger.warn("Encountered error during upload. ")
            }

            let failureMode: Upload.FailureMode
            var latestUploadProgress: Upload.ResumeProgress?
            var remoteConfirmedProgress = false
            switch error {
            case .partialUpload(let bytesUploaded):
                attempt.logger.info("Endpoint successfully uploaded chunk of \(bytesUploaded) bytes.")
                remoteConfirmedProgress = true
                failureMode = .resume(.afterBackoff)
            case .uploadFailure(let retryMode):
                // if a failure mode was passed back
                failureMode = retryMode
            case .networkTimeout:
                // if this isn't an understood error, map into a failure mode
                // fetch the progress to determine if we've made progress.
                latestUploadProgress = try? await getResumableUploadProgress(forAttempt: attempt)
                switch latestUploadProgress {
                case .complete:
                    remoteConfirmedProgress = true
                    failureMode = .resume(.afterBackoff)
                case .restart:
                    failureMode = .restart(.afterBackoff)
                case .none:
                    failureMode = .resume(.afterBackoff)
                case .uploaded(let remoteByteCount):
                    attempt.logger.info("Endpoint reported \(remoteByteCount)/\(attempt.encryptedDataLength) uploaded.")
                    if remoteByteCount > bytesAlreadyUploaded {
                        // The remote endpoint reports progress was made, so retry immediately.
                        remoteConfirmedProgress = true
                        attempt.logger.info("Endpoint reported we made progress: \(bytesAlreadyUploaded) -> \(remoteByteCount) (\(downloadTimeLogString(remoteByteCount)))")
                    }
                    failureMode = .resume(.afterBackoff)
                }
            case .networkError:
                failureMode = .resume(.afterBackoff)
            case .missingFile:
                attempt.logger.error("Missing attachment file!")
                failureMode = .noMoreRetries
            case .invalidUploadURL, .unsupportedEndpoint, .unexpectedResponseStatusCode, .unknown:
                // These errors are unrecoverable, so restart the upload in hopes of correcting the issue.
                failureMode = .restart(.afterBackoff)
            }

            switch failureMode {
            case .noMoreRetries:
                attempt.logger.warn("No more retries.")
                throw error
            case .resume(let recoveryMode):
                switch recoveryMode {
                case .afterBackoff where remoteConfirmedProgress:
                    // If we confirmed that we made progress, we want to retry immediately.
                    // This may be because we uploaded a single chunk (and have more chunks to
                    // upload) or because we got interrupted partway through and want to start
                    // again immediately. (This flag requires positive confirmation that the
                    // server accepted some number of bytes we sent.)
                    break
                case .afterBackoff:
                    let backoff = OWSOperation.retryIntervalForExponentialBackoff(failureCount: failureCount, maxAverageBackoff: 14.1 * .minute)
                    attempt.logger.warn(String(format: "Retry upload after %.3f seconds.", backoff))
                    try await sleepTimer.sleep(for: backoff)
                case .afterServerRequestedDelay(let delay):
                    attempt.logger.warn(String(format: "Retry upload after %.3f seconds.", delay))
                    try await sleepTimer.sleep(for: delay)
                }
            case .restart:
                // Restart is handled at a higher level since the whole
                // upload form needs to be rebuilt.
                throw Upload.Error.uploadFailure(recovery: failureMode)
            }

            attempt.logger.info("Resuming upload.")
            // Reset the attempt count to 1 as long as remote progress was made. Make it 1, since 0
            // will behave like a fresh upload and skip fetching the remote upload progress.
            let nextFailureCount = remoteConfirmedProgress ? 1 : failureCount + 1
            try await performResumableUpload(
                attempt: attempt,
                sleepTimer: sleepTimer,
                failureCount: nextFailureCount,
                priorUploadProgress: latestUploadProgress,
                progress: progress,
            )
        }
    }

    // MARK: - Helper Methods

    public static func buildAttempt(
        for localMetadata: Upload.LocalUploadMetadata,
        form: Upload.Form,
        existingSessionUrl: URL? = nil,
        signalService: OWSSignalServiceProtocol,
        fileSystem: Upload.Shims.FileSystem,
        dateProvider: @escaping DateProvider,
        logger: PrefixedLogger,
    ) async throws -> Upload.Attempt<Upload.LocalUploadMetadata> {
        return try await buildAttempt(
            for: localMetadata,
            fileUrl: localMetadata.fileUrl,
            encryptedDataLength: localMetadata.encryptedDataLength,
            form: form,
            existingSessionUrl: existingSessionUrl,
            signalService: signalService,
            fileSystem: fileSystem,
            dateProvider: dateProvider,
            logger: logger,
        )
    }

    public static func buildAttempt(
        for metadata: Upload.LinkNSyncUploadMetadata,
        form: Upload.Form,
        existingSessionUrl: URL? = nil,
        signalService: OWSSignalServiceProtocol,
        fileSystem: Upload.Shims.FileSystem,
        dateProvider: @escaping DateProvider,
        logger: PrefixedLogger,
    ) async throws -> Upload.Attempt<Upload.LinkNSyncUploadMetadata> {
        return try await buildAttempt(
            for: metadata,
            fileUrl: metadata.fileUrl,
            encryptedDataLength: metadata.encryptedDataLength,
            form: form,
            existingSessionUrl: existingSessionUrl,
            signalService: signalService,
            fileSystem: fileSystem,
            dateProvider: dateProvider,
            logger: logger,
        )
    }

    public static func buildAttempt(
        for localMetadata: Upload.EncryptedBackupUploadMetadata,
        form: Upload.Form,
        existingSessionUrl: URL? = nil,
        signalService: OWSSignalServiceProtocol,
        fileSystem: Upload.Shims.FileSystem,
        dateProvider: @escaping DateProvider,
        logger: PrefixedLogger,
    ) async throws -> Upload.Attempt<Upload.EncryptedBackupUploadMetadata> {
        return try await buildAttempt(
            for: localMetadata,
            fileUrl: localMetadata.fileUrl,
            encryptedDataLength: localMetadata.encryptedDataLength,
            form: form,
            existingSessionUrl: existingSessionUrl,
            signalService: signalService,
            fileSystem: fileSystem,
            dateProvider: dateProvider,
            logger: logger,
        )
    }

    public static func buildAttempt<Metadata: UploadMetadata>(
        for localMetadata: Metadata,
        fileUrl: URL,
        encryptedDataLength: UInt32,
        form: Upload.Form,
        existingSessionUrl: URL? = nil,
        signalService: OWSSignalServiceProtocol,
        fileSystem: Upload.Shims.FileSystem,
        dateProvider: @escaping DateProvider,
        logger: PrefixedLogger,
    ) async throws -> Upload.Attempt<Metadata> {
        let endpoint: UploadEndpoint = try {
            switch form.cdnNumber {
            case 2:
                return UploadEndpointCDN2(
                    form: form,
                    signalService: signalService,
                    fileSystem: fileSystem,
                    logger: logger,
                )
            case 3:
                return UploadEndpointCDN3(
                    form: form,
                    signalService: signalService,
                    fileSystem: fileSystem,
                    logger: logger,
                )
            default:
                throw OWSAssertionError("Unsupported Endpoint: \(form.cdnNumber)")
            }
        }()
        let uploadLocation = try await {
            if let existingSessionUrl {
                return existingSessionUrl
            }
            return try await endpoint.fetchResumableUploadLocation()
        }()
        return Upload.Attempt(
            cdnKey: form.cdnKey,
            cdnNumber: form.cdnNumber,
            fileUrl: fileUrl,
            encryptedDataLength: encryptedDataLength,
            localMetadata: localMetadata,
            beginTimestamp: dateProvider().ows_millisecondsSince1970,
            endpoint: endpoint,
            uploadLocation: uploadLocation,
            isResumedUpload: existingSessionUrl != nil,
            logger: logger,
        )
    }
}
