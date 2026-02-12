//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public struct BackupExportJobStore {

    private enum Keys {
        static let resumptionPoint = "resumptionPoint"
    }

    private let kvStore: NewKeyValueStore

    public init() {
        self.kvStore = NewKeyValueStore(collection: "BackupExportJobStore")
    }

    // MARK: -

    /// Represents a point at which an interrupted `BackupExportJob` can be
    /// resumed.
    public enum ResumptionPoint: Int64 {
        /// The job should be resumed from the beginning.
        case beginning
        /// The job should be resumed after Backup-file-related stages.
        case postBackupFile
    }

    public func lastReachedResumptionPoint(tx: DBReadTransaction) -> ResumptionPoint? {
        return kvStore.fetchValue(Int64.self, forKey: Keys.resumptionPoint, tx: tx)
            .flatMap { ResumptionPoint(rawValue: $0) }
    }

    public func setReachedResumptionPoint(_ point: ResumptionPoint?, tx: DBWriteTransaction) {
        kvStore.writeValue(point?.rawValue, forKey: Keys.resumptionPoint, tx: tx)
    }
}
