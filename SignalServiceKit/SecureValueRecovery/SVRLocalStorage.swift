//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Stores state related to SVR; e.g. do we have backups at all, etc.
public struct SVRLocalStorage {
    let backupAttemptStore = KeyValueStore(collection: "SVR.Completed")

    public func isMasterKeyBackedUp(tx: DBReadTransaction) -> Bool {
        return !backupAttemptStore.allKeys(transaction: tx).isEmpty
    }
}
