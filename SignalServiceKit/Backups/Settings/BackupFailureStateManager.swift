//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public class BackupFailureStateManager {
    private let backupSettingsStore: BackupSettingsStore
    private let dateProvider: DateProvider
    private let tsAccountManager: TSAccountManager

    init(
        backupSettingsStore: BackupSettingsStore,
        dateProvider: @escaping DateProvider,
        tsAccountManager: TSAccountManager,
    ) {
        self.backupSettingsStore = backupSettingsStore
        self.dateProvider = dateProvider
        self.tsAccountManager = tsAccountManager
    }

    // MARK: -

    /// Allow for managing backup badge state from arbitrary points.
    /// This allows each target to be separately cleared, and also allows
    /// backups to reset the state for all of them on a failure
    public func shouldShowErrorBadge(target: String, tx: DBReadTransaction) -> Bool {
        guard shouldBackupsBeRunning(tx: tx) else {
            return false
        }

        // See if this badge has been muted
        if backupSettingsStore.getErrorBadgeMuted(target: target, tx: tx) {
            return false
        }

        if backupSettingsStore.getLastBackupFailed(tx: tx) {
            return true
        }

        if !lastBackupWasRecent(tx: tx) {
            return true
        }

        return false
    }

    public func clearErrorBadge(target: String, tx: DBWriteTransaction) {
        // set this target as muted
        backupSettingsStore.setErrorBadgeMuted(target: target, tx: tx)
    }

    // MARK: -

    private func shouldBackupsBeRunning(tx: DBReadTransaction) -> Bool {
        guard tsAccountManager.registrationState(tx: tx).isRegisteredPrimaryDevice else {
            // No backups on iPad, so no errors.
            return false
        }

        return switch backupSettingsStore.backupPlan(tx: tx) {
        case .disabled, .disabling: false
        case .free, .paid, .paidExpiringSoon, .paidAsTester: true
        }
    }

    /// Whether the user's last successful Backup happened "recently".
    private func lastBackupWasRecent(tx: DBReadTransaction) -> Bool {
        // Get the last successful backup, or if it's never succeeded the last
        // time backups were enabled.
        let lastBackupDate: Date? = {
            if let lastBackupDate = backupSettingsStore.lastBackupDate(tx: tx) {
                return lastBackupDate
            }

            if let lastBackupEnabledTime = backupSettingsStore.lastBackupEnabledDetails(tx: tx)?.enabledTime {
                return lastBackupEnabledTime
            }

            return nil
        }()

        guard let lastBackupDate else {
            return false
        }

        return dateProvider().timeIntervalSince(lastBackupDate) < .week
    }
}
