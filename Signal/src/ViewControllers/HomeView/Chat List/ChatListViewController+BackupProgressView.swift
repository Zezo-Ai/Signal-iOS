//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import PureLayout
import SignalServiceKit
import SignalUI
import UIKit

private extension Notification.Name {
    static let isHiddenDidChange = Notification.Name("CLVBackupProgressView.isHiddenDidChange")
}

class CLVBackupProgressView: BackupProgressView.Delegate {

    struct Store {
        private enum Keys {
            static let isHidden = "isHidden"
            static let earliestBackupDateToConsider = "earliestBackupDateToConsider"
        }

        private let kvStore = NewKeyValueStore(collection: "CLVBackupProgressView")

        func isHidden(tx: DBReadTransaction) -> Bool {
            return kvStore.fetchValue(Bool.self, forKey: Keys.isHidden, tx: tx) ?? false
        }

        func setIsHidden(_ value: Bool, tx: DBWriteTransaction) {
            kvStore.writeValue(value, forKey: Keys.isHidden, tx: tx)

            tx.addSyncCompletion {
                NotificationCenter.default.postOnMainThread(
                    name: .isHiddenDidChange,
                    object: nil,
                )
            }
        }

        fileprivate func earliestBackupDateToConsider(tx: DBReadTransaction) -> Date? {
            kvStore.fetchValue(Date.self, forKey: Keys.earliestBackupDateToConsider, tx: tx)
        }

        fileprivate func setEarliestBackupDateToConsider(_ value: Date, tx: DBWriteTransaction) {
            kvStore.writeValue(value, forKey: Keys.earliestBackupDateToConsider, tx: tx)
        }
    }

    private struct State {
        var isVisible: Bool = false
        var deviceSleepBlock: DeviceSleepBlockObject?

        var earliestBackupDateToConsider: Date = .distantFuture
        var isHidden: Bool = false
        var lastBackupDetails: BackupSettingsStore.LastBackupDetails?

        // nil if we've never yet gotten an update. .some(nil) if we have gotten
        // an update, and that update was nil.
        var lastExportJobProgressUpdate: OWSSequentialProgress<BackupExportJobStage>??
        var lastUploadTrackerUpdate: BackupAttachmentUploadTracker.UploadUpdate?

        var updateStreamTasks: [Task<Void, Never>] = []
    }

    private let backupAttachmentUploadTracker: BackupAttachmentUploadTracker
    private let backupExportJobRunner: BackupExportJobRunner
    private let backupSettingsStore: BackupSettingsStore
    private let dateProvider: DateProvider
    private let db: DB
    private let deviceSleepManager: DeviceSleepManager
    private let store: Store

    weak var chatListViewController: ChatListViewController?
    lazy var backupProgressViewCell: UITableViewCell = Self.tableViewCell(wrapping: backupProgressView)

    private let backupProgressView: BackupProgressView
    private let state: AtomicValue<State>

    init() {
        self.backupAttachmentUploadTracker = AppEnvironment.shared.backupAttachmentUploadTracker
        self.backupExportJobRunner = DependenciesBridge.shared.backupExportJobRunner
        self.backupSettingsStore = BackupSettingsStore()
        self.dateProvider = { Date() }
        self.db = DependenciesBridge.shared.db
        self.deviceSleepManager = DependenciesBridge.shared.deviceSleepManager.owsFailUnwrap("Missing DeviceSleepManager!")
        self.store = Store()

        self.backupProgressView = BackupProgressView(viewState: nil)
        self.state = AtomicValue(State(), lock: .init())

        self.backupProgressView.delegate = self
    }

    fileprivate static func tableViewCell(wrapping backupProgressView: BackupProgressView) -> UITableViewCell {
        let cell = UITableViewCell()
        var backgroundConfiguration = UIBackgroundConfiguration.clear()
        backgroundConfiguration.backgroundColor = .Signal.background
        cell.backgroundConfiguration = backgroundConfiguration

        cell.contentView.addSubview(backupProgressView)
        backupProgressView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 12, vMargin: 12))
        return cell
    }

    // MARK: -

    var shouldBeVisible: Bool {
        return backupProgressView.viewState != nil
    }

    // MARK: -

    @MainActor
    func willAppear() {
        state.update { _state in
            _state.isVisible = true
            manageDeviceSleepBlock(state: &_state)
        }
    }

    @MainActor
    func didDisapper() {
        state.update { _state in
            _state.isVisible = false
            manageDeviceSleepBlock(state: &_state)
        }
    }

    // MARK: -

    func startTracking() {
        let storedEarliestBackupDateToConsider: Date?
        let isHidden: Bool
        let lastBackupDetails: BackupSettingsStore.LastBackupDetails?
        (
            storedEarliestBackupDateToConsider,
            isHidden,
            lastBackupDetails,
        ) = db.read { tx in
            (
                store.earliestBackupDateToConsider(tx: tx),
                store.isHidden(tx: tx),
                backupSettingsStore.lastBackupDetails(tx: tx),
            )
        }

        // As a one-time migration, store "now" as the earliest Backup date to
        // consider. This avoids us showing the "Complete" state for users who
        // already had Backups enabled and running when we introduced this view.
        let earliestBackupDateToConsider: Date
        if let storedEarliestBackupDateToConsider {
            earliestBackupDateToConsider = storedEarliestBackupDateToConsider
        } else {
            earliestBackupDateToConsider = dateProvider()
            db.write { tx in
                store.setEarliestBackupDateToConsider(earliestBackupDateToConsider, tx: tx)
            }
        }

        state.update { _state in
            guard _state.updateStreamTasks.isEmpty else { return }

            _state.earliestBackupDateToConsider = earliestBackupDateToConsider
            _state.isHidden = isHidden
            _state.lastBackupDetails = lastBackupDetails

            _state.updateStreamTasks = _startTracking()
        }
    }

    private func _startTracking() -> [Task<Void, Never>] {
        return [
            Task { @MainActor [weak self, backupAttachmentUploadTracker] in
                for await uploadTrackerUpdate in backupAttachmentUploadTracker.updates() {
                    guard let self else { return }

                    state.update { _state in
                        _state.lastUploadTrackerUpdate = .some(uploadTrackerUpdate)
                        self.setViewStateForState(state: &_state)
                    }
                }
            },
            Task { @MainActor [weak self, backupExportJobRunner] in
                for await exportJobUpdate in backupExportJobRunner.updates() {
                    guard let self else { return }

                    state.update { _state in
                        switch exportJobUpdate {
                        case .progress(let progressUpdate):
                            _state.lastExportJobProgressUpdate = progressUpdate
                        case nil, .completion:
                            _state.lastExportJobProgressUpdate = .some(nil)
                        }
                        self.setViewStateForState(state: &_state)
                    }
                }
            },
            NotificationCenter.default.startTaskTrackingNotifications(
                named: .lastBackupDetailsDidChange,
                onNotification: { [weak self] in
                    guard let self else { return }

                    let lastBackupDetails = db.read { tx in
                        self.backupSettingsStore.lastBackupDetails(tx: tx)
                    }

                    state.update { _state in
                        _state.lastBackupDetails = lastBackupDetails
                        self.setViewStateForState(state: &_state)
                    }
                },
            ),
            NotificationCenter.default.startTaskTrackingNotifications(
                named: .isHiddenDidChange,
                onNotification: { [weak self] in
                    guard let self else { return }

                    let isHidden = db.read { tx in
                        self.store.isHidden(tx: tx)
                    }

                    state.update { _state in
                        _state.isHidden = isHidden
                        self.setViewStateForState(state: &_state)
                    }
                },
            ),
        ]
    }

    // MARK: -

    private let chatListReloadQueue = SerialTaskQueue()

    @MainActor
    private func setViewStateForState(state: inout State) {
        let oldViewState = backupProgressView.viewState
        let newViewState = viewStateForState(state: state)

        chatListReloadQueue.enqueue { @MainActor [self] in
            if oldViewState != newViewState {
                backupProgressView.viewState = newViewState
            }

            if (oldViewState == nil) != (newViewState == nil) {
                // We're hiding/showing the view: reload the chat list.
                chatListViewController?.loadCoordinator.loadIfNecessary()
            } else if oldViewState?.id != newViewState?.id {
                // Our height may change when we change view states, so tell the
                // table view to recompute.
                chatListViewController?.tableView.recomputeRowHeights()
            }
        }

        manageDeviceSleepBlock(state: &state)
    }

    private func viewStateForState(state: State) -> BackupProgressView.ViewState? {
        guard
            let lastExportJobProgressUpdate = state.lastExportJobProgressUpdate,
            let lastUploadTrackerUpdate = state.lastUploadTrackerUpdate
        else {
            // Never show the view until we've received our initial updates.
            return nil
        }

        if state.isHidden {
            return nil
        }

        if let progressUpdate = lastExportJobProgressUpdate {
            switch progressUpdate.currentStep {
            case .backupFileExport, .backupFileUpload:
                let percentExportCompleted = progressUpdate.progress(for: .backupFileExport)?.percentComplete ?? 0
                let percentUploadCompleted = progressUpdate.progress(for: .backupFileUpload)?.percentComplete ?? 0
                let percentComplete = (0.95 * percentExportCompleted) + (0.05 * percentUploadCompleted)
                return .backupFilePreparation(percentComplete: percentComplete)
            case .attachmentUpload, .attachmentProcessing:
                break
            }
        }

        switch lastUploadTrackerUpdate.state {
        case .noUploadsToReport:
            break
        case .uploading:
            return .attachmentUploadRunning(
                bytesUploaded: lastUploadTrackerUpdate.bytesUploaded,
                totalBytesToUpload: lastUploadTrackerUpdate.totalBytesToUpload,
            )
        case .suspended,
             .notRegisteredAndReady,
             .hasConsumedMediaTierCapacity:
            return nil
        case .pausedLowBattery:
            return .attachmentUploadPausedLowBattery
        case .pausedLowPowerMode:
            return .attachmentUploadPausedLowPowerMode
        case .pausedNeedsWifi:
            return .attachmentUploadPausedNoWifi
        case .pausedNeedsInternet:
            return .attachmentUploadPausedNoInternet
        }

        // Check this after uploads, since we don't want to show "complete"
        // until uploads are done even if we've made a Backup file.
        if
            let lastBackupDetails = state.lastBackupDetails,
            lastBackupDetails.date > state.earliestBackupDateToConsider
        {
            return .complete
        }

        return nil
    }

    @MainActor
    private func manageDeviceSleepBlock(state: inout State) {
        var shouldBlockDeviceSleep = switch backupProgressView.viewState {
        case .backupFilePreparation: true
        case .attachmentUploadRunning: true
        case .attachmentUploadPausedNoWifi: false
        case .attachmentUploadPausedNoInternet: false
        case .attachmentUploadPausedLowBattery: false
        case .attachmentUploadPausedLowPowerMode: false
        case .complete: false
        case nil: false
        }

        shouldBlockDeviceSleep = shouldBlockDeviceSleep && state.isVisible

        if
            shouldBlockDeviceSleep,
            state.deviceSleepBlock == nil
        {
            let deviceSleepBlock = DeviceSleepBlockObject(blockReason: "CLVBackupProgressView")
            deviceSleepManager.addBlock(blockObject: deviceSleepBlock)
            state.deviceSleepBlock = deviceSleepBlock
        } else if
            !shouldBlockDeviceSleep,
            let deviceSleepBlock = state.deviceSleepBlock.take()
        {
            deviceSleepManager.removeBlock(blockObject: deviceSleepBlock)
        }
    }

    // MARK: - ExportProgressView.Delegate

    func didTapDismissButton() {
        db.write { tx in
            store.setIsHidden(true, tx: tx)
        }
    }

    func didTapPausedWifiResumeButton() {
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_RESUME_CELLULAR_DATA_TITLE",
                comment: "Title for the action sheet shown when the user tries to resume backup using cellular data.",
            ),
            message: OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_RESUME_CELLULAR_DATA_MESSAGE",
                comment: "Message shown in an action sheet when the user tries to resume backup using cellular data.",
            ),
        )
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_RESUME_CELLULAR_DATA_BUTTON",
                comment: "Button in the action sheet to resume backup using cellular data.",
            ),
            handler: { [self] _ in
                db.write { tx in
                    backupSettingsStore.setShouldAllowBackupUploadsOnCellular(true, tx: tx)
                }
            },
        ))
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_LATER_ON_WIFI_BUTTON",
                comment: "Button in the action sheet to dismiss and resume backup later on Wi-Fi.",
            ),
        ))

        chatListViewController?.presentActionSheet(actionSheet)
    }

    // MARK: -

    /// Actions to display in a context menu for the owning row in the table
    /// view.
    func contextMenuActions() -> [UIAction] {
        let hideAction = UIAction(
            title: OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_HIDE_CONTEXT_MENU_ACTION",
                comment: "Title for the context menu action that hides the backup progress view.",
            ),
            image: .eyeSlash,
        ) { [self] _ in
            db.write { tx in
                store.setIsHidden(true, tx: tx)
            }
            chatListViewController?.presentToast(text: OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_HIDE_TOAST",
                comment: "Toast shown after the user hides the backup progress view.",
            ))
        }

        let cancelAction = UIAction(
            title: OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_CANCEL_BACKUP_CONTEXT_MENU_ACTION",
                comment: "Title for the context menu action that cancels the backup.",
            ),
            image: .xCircle,
        ) { [self] _ in
            let actionSheet = ActionSheetController(
                title: OWSLocalizedString(
                    "CHAT_LIST_BACKUP_PROGRESS_VIEW_BACKUP_CANCEL_CONFIRMATION_TITLE",
                    comment: "Title for the action sheet shown when the user tries to cancel a backup.",
                ),
                message: OWSLocalizedString(
                    "CHAT_LIST_BACKUP_PROGRESS_VIEW_BACKUP_CANCEL_CONFIRMATION_MESSAGE",
                    comment: "Message shown in an action sheet when the user tries to cancel a backup.",
                ),
            )
            actionSheet.addAction(ActionSheetAction(
                title: OWSLocalizedString(
                    "CHAT_LIST_BACKUP_PROGRESS_VIEW_CANCEL_BACKUP_BUTTON",
                    comment: "Button in the cancel backup action sheet that confirms cancellation.",
                ),
                handler: { [self] _ in
                    // Cancel the BackupExportJob, and pause uploads.
                    backupExportJobRunner.cancelIfRunning()
                    db.write {
                        backupSettingsStore.setIsBackupUploadQueueSuspended(true, tx: $0)
                    }
                    chatListViewController?.presentToast(text: OWSLocalizedString(
                        "CHAT_LIST_BACKUP_PROGRESS_VIEW_BACKUP_CANCELED_TOAST",
                        comment: "Toast shown after the user cancels the backup.",
                    ))
                },
            ))
            actionSheet.addAction(ActionSheetAction(
                title: OWSLocalizedString(
                    "CHAT_LIST_BACKUP_PROGRESS_VIEW_CONTINUE_BACKUP_BUTTON",
                    comment: "Button in the cancel backup action sheet that dismisses the sheet and continues the backup.",
                ),
            ))
            chatListViewController?.presentActionSheet(actionSheet)
        }

        switch backupProgressView.viewState {
        case nil:
            return []
        case .complete:
            return [hideAction]
        case .backupFilePreparation,
             .attachmentUploadRunning,
             .attachmentUploadPausedNoWifi,
             .attachmentUploadPausedNoInternet,
             .attachmentUploadPausedLowBattery,
             .attachmentUploadPausedLowPowerMode:
            return [hideAction, cancelAction]
        }
    }
}

// MARK: -

extension ChatListViewController {
    func handleBackupProgressViewTapped() {
        SignalApp.shared.showAppSettings(mode: .backups())
    }
}

// MARK: -

private class BackupProgressView: UIView {

    protocol Delegate: AnyObject {
        func didTapDismissButton()
        func didTapPausedWifiResumeButton()
    }

    enum ViewState: Equatable, Identifiable {
        case backupFilePreparation(percentComplete: Float)
        case attachmentUploadRunning(bytesUploaded: UInt64, totalBytesToUpload: UInt64)
        case attachmentUploadPausedNoWifi
        case attachmentUploadPausedNoInternet
        case attachmentUploadPausedLowBattery
        case attachmentUploadPausedLowPowerMode
        case complete

        var id: String {
            return switch self {
            case .backupFilePreparation: "backupFilePreparation"
            case .attachmentUploadRunning: "attachmentUploadRunning"
            case .attachmentUploadPausedNoWifi: "attachmentUploadPausedNoWifi"
            case .attachmentUploadPausedNoInternet: "attachmentUploadPausedNoInternet"
            case .attachmentUploadPausedLowBattery: "attachmentUploadPausedLowBattery"
            case .attachmentUploadPausedLowPowerMode: "attachmentUploadPausedLowPowerMode"
            case .complete: "complete"
            }
        }
    }

    /// If `nil`, this view isn't visible.
    var viewState: ViewState? {
        didSet {
            configureSubviewsForCurrentState()
        }
    }

    // MARK: -

    private static func configure(
        label: UILabel,
        font: UIFont = .dynamicTypeSubheadline,
        color: UIColor,
    ) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        label.font = .monospacedDigitFont(ofSize: font.pointSize)
        label.textColor = color
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
    }

    // MARK: -

    private lazy var leadingAccessoryImageView = UIImageView()

    private lazy var labelStackView = UIStackView()
    private lazy var titleLabel = UILabel()
    private lazy var progressLabel = UILabel()

    /// A container for the various trailingAccessory views we might display. A
    /// stack view so we can use `isHidden = true` to make subviews take up zero
    /// space.
    private lazy var trailingAccessoryContainerView = UIStackView()
    private lazy var trailingAccessoryRunningArcView = ArcView()
    private lazy var trailingAccessoryPausedWifiResumeButton = UIButton()
    private lazy var trailingAccessoryPausedNoInternetLabel = UILabel()
    private lazy var trailingAccessoryPausedLowBatteryLabel = UILabel()
    private lazy var trailingAccessoryPausedLowPowerModeLabel = UILabel()
    private lazy var trailingAccessoryCompleteDismissButton = UIButton()

    weak var delegate: Delegate?

    init(viewState: ViewState?) {
        self.viewState = viewState

        super.init(frame: .zero)

        backgroundColor = .Signal.quaternaryFill
        layer.cornerRadius = 24
        layoutMargins = UIEdgeInsets(hMargin: 16, vMargin: 12)

        addSubview(leadingAccessoryImageView)
        leadingAccessoryImageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelStackView)
        labelStackView.translatesAutoresizingMaskIntoConstraints = false
        labelStackView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelStackView.alignment = .fill
        labelStackView.axis = .vertical
        labelStackView.spacing = 4

        labelStackView.addArrangedSubview(titleLabel)
        Self.configure(label: titleLabel, color: .Signal.label)

        labelStackView.addArrangedSubview(progressLabel)
        Self.configure(label: progressLabel, font: .dynamicTypeFootnote, color: .Signal.secondaryLabel)

        addSubview(trailingAccessoryContainerView)
        trailingAccessoryContainerView.alignment = .trailing
        trailingAccessoryContainerView.translatesAutoresizingMaskIntoConstraints = false

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryRunningArcView)
        trailingAccessoryRunningArcView.translatesAutoresizingMaskIntoConstraints = false

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedWifiResumeButton)
        trailingAccessoryPausedWifiResumeButton.translatesAutoresizingMaskIntoConstraints = false
        trailingAccessoryPausedWifiResumeButton.setTitle(
            OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_RESUME_WIFI_BUTTON",
                comment: "Button shown in the backup progress view trailing accessory to resume uploading over Wi-Fi.",
            ),
            for: .normal,
        )
        trailingAccessoryPausedWifiResumeButton.setTitleColor(.Signal.label, for: .normal)
        trailingAccessoryPausedWifiResumeButton.titleLabel?.font = .dynamicTypeSubheadline.semibold()
        trailingAccessoryPausedWifiResumeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        trailingAccessoryPausedWifiResumeButton.addAction(
            UIAction { [weak self] _ in
                self?.delegate?.didTapPausedWifiResumeButton()
            },
            for: .touchUpInside,
        )

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryCompleteDismissButton)
        trailingAccessoryCompleteDismissButton.translatesAutoresizingMaskIntoConstraints = false
        trailingAccessoryCompleteDismissButton.setImage(.x, animated: false)
        trailingAccessoryCompleteDismissButton.tintColor = .Signal.secondaryLabel
        trailingAccessoryCompleteDismissButton.addAction(
            UIAction { [weak self] _ in
                self?.delegate?.didTapDismissButton()
            },
            for: .touchUpInside,
        )

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedNoInternetLabel)
        Self.configure(label: trailingAccessoryPausedNoInternetLabel, color: .Signal.secondaryLabel)
        trailingAccessoryPausedNoInternetLabel.text = OWSLocalizedString(
            "CHAT_LIST_BACKUP_PROGRESS_VIEW_NO_INTERNET_LABEL",
            comment: "Trailing accessory label shown when backup is paused due to no internet connection.",
        )

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedLowBatteryLabel)
        Self.configure(label: trailingAccessoryPausedLowBatteryLabel, color: .Signal.secondaryLabel)
        trailingAccessoryPausedLowBatteryLabel.text = OWSLocalizedString(
            "CHAT_LIST_BACKUP_PROGRESS_VIEW_LOW_BATTERY_LABEL",
            comment: "Trailing accessory label shown when backup is paused due to low battery.",
        )

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedLowPowerModeLabel)
        Self.configure(label: trailingAccessoryPausedLowPowerModeLabel, color: .Signal.secondaryLabel)
        trailingAccessoryPausedLowPowerModeLabel.text = OWSLocalizedString(
            "CHAT_LIST_BACKUP_PROGRESS_VIEW_LOW_POWER_MODE_LABEL",
            comment: "Trailing accessory label shown when backup is paused due to Low Power Mode.",
        )

        initializeConstraints()
        configureSubviewsForCurrentState()
    }

    required init?(coder: NSCoder) {
        owsFail("Not implemented!")
    }

    // MARK: -

    private func configureSubviewsForCurrentState() {
        // Leading accessory
        switch viewState {
        case nil,
             .backupFilePreparation,
             .attachmentUploadRunning,
             .attachmentUploadPausedNoWifi,
             .attachmentUploadPausedNoInternet,
             .attachmentUploadPausedLowBattery,
             .attachmentUploadPausedLowPowerMode:
            leadingAccessoryImageView.image = .backup
            leadingAccessoryImageView.tintColor = .Signal.label
        case .complete:
            leadingAccessoryImageView.image = .checkCircle
            leadingAccessoryImageView.tintColor = .Signal.ultramarine
        }

        // Labels
        let titleLabelText: String
        var progressLabelText: String?
        switch viewState {
        case .backupFilePreparation(let percentComplete):
            titleLabelText = OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_PREPARING_BACKUP_TITLE",
                comment: "Title label shown in the chat list backup progress view while the backup file is being prepared.",
            )
            progressLabelText = percentComplete.formatted(.owsPercent())
        case .attachmentUploadRunning(let bytesUploaded, let totalBytesToUpload):
            titleLabelText = OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_UPLOADING_BACKUP_TITLE",
                comment: "Title label shown in the chat list backup progress view while backup attachments are being uploaded.",
            )
            progressLabelText = String(
                format: OWSLocalizedString(
                    "CHAT_LIST_BACKUP_PROGRESS_VIEW_UPLOAD_PROGRESS_FORMAT",
                    comment: "Progress label showing the amount uploaded out of the total. Embeds {{ %1$@ bytes uploaded, %2$@ total bytes to upload }}.",
                ),
                bytesUploaded.formatted(.owsByteCount()),
                totalBytesToUpload.formatted(.owsByteCount()),
            )
        case .attachmentUploadPausedNoWifi:
            titleLabelText = OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_WAITING_FOR_WIFI_TITLE",
                comment: "Title label shown in the chat list backup progress view when waiting for Wi-Fi.",
            )
        case .attachmentUploadPausedNoInternet,
             .attachmentUploadPausedLowBattery,
             .attachmentUploadPausedLowPowerMode:
            titleLabelText = OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_BACKUP_PAUSED_TITLE",
                comment: "Title label shown in the chat list backup progress view when the backup is paused.",
            )
        case .complete:
            titleLabelText = OWSLocalizedString(
                "CHAT_LIST_BACKUP_PROGRESS_VIEW_BACKUP_COMPLETE_TITLE",
                comment: "Title label shown in the chat list backup progress view when the backup is complete.",
            )
        case nil:
            titleLabelText = ""
        }
        titleLabel.text = titleLabelText
        if let progressLabelText {
            progressLabel.text = progressLabelText
            progressLabel.isHidden = false
        } else {
            progressLabel.isHidden = true
        }

        // Trailing accessory
        let trailingAccessoryView: UIView?
        switch viewState {
        case .backupFilePreparation(let percentComplete):
            trailingAccessoryRunningArcView.percentComplete = percentComplete
            trailingAccessoryView = trailingAccessoryRunningArcView
        case .attachmentUploadRunning(let bytesUploaded, let totalBytesToUpload):
            trailingAccessoryRunningArcView.percentComplete = Float(bytesUploaded) / Float(totalBytesToUpload)
            trailingAccessoryView = trailingAccessoryRunningArcView
        case .attachmentUploadPausedNoWifi:
            trailingAccessoryView = trailingAccessoryPausedWifiResumeButton
        case .attachmentUploadPausedNoInternet:
            trailingAccessoryView = trailingAccessoryPausedNoInternetLabel
        case .attachmentUploadPausedLowBattery:
            trailingAccessoryView = trailingAccessoryPausedLowBatteryLabel
        case .attachmentUploadPausedLowPowerMode:
            trailingAccessoryView = trailingAccessoryPausedLowPowerModeLabel
        case .complete:
            trailingAccessoryView = trailingAccessoryCompleteDismissButton
        case nil:
            trailingAccessoryView = nil
        }

        // Hide all but at most one trailingAccessory view.
        for view in trailingAccessoryContainerView.arrangedSubviews {
            if view == trailingAccessoryView {
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
    }

    // MARK: -

    private func initializeConstraints() {
        NSLayoutConstraint.activate([
            leadingAccessoryImageView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            leadingAccessoryImageView.centerYAnchor.constraint(equalTo: labelStackView.centerYAnchor),
            leadingAccessoryImageView.heightAnchor.constraint(equalToConstant: 24),
            leadingAccessoryImageView.widthAnchor.constraint(equalToConstant: 24),

            labelStackView.leadingAnchor.constraint(equalTo: leadingAccessoryImageView.trailingAnchor, constant: 12),
            labelStackView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            labelStackView.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            labelStackView.trailingAnchor.constraint(equalTo: trailingAccessoryContainerView.leadingAnchor, constant: -12),

            trailingAccessoryContainerView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            trailingAccessoryContainerView.centerYAnchor.constraint(equalTo: labelStackView.centerYAnchor),

            trailingAccessoryRunningArcView.heightAnchor.constraint(equalToConstant: 24),
            trailingAccessoryRunningArcView.widthAnchor.constraint(equalToConstant: 24),

            trailingAccessoryCompleteDismissButton.heightAnchor.constraint(equalToConstant: 24),
            trailingAccessoryCompleteDismissButton.widthAnchor.constraint(equalToConstant: 24),
        ])
    }
}

// MARK: -

#if DEBUG

private class BackupProgressViewPreviewViewController: TablePreviewViewController {
    init(state: BackupProgressView.ViewState?) {
        super.init { _ -> [UITableViewCell] in
            return [
                CLVBackupProgressView.tableViewCell(wrapping: BackupProgressView(
                    viewState: state,
                )),
                {
                    let cell = UITableViewCell()
                    var content = cell.defaultContentConfiguration()
                    content.text = "Imagine this is a ChatListCell :)"
                    cell.contentConfiguration = content
                    return cell
                }(),
            ]
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

@available(iOS 17, *)
#Preview("Preparing") {
    return BackupProgressViewPreviewViewController(state: .backupFilePreparation(percentComplete: 0.33))
}

@available(iOS 17, *)
#Preview("Running") {
    return BackupProgressViewPreviewViewController(state: .attachmentUploadRunning(
        bytesUploaded: 1_000_000_000,
        totalBytesToUpload: 2_400_000_000,
    ))
}

@available(iOS 17, *)
#Preview("Paused: WiFi") {
    return BackupProgressViewPreviewViewController(state: .attachmentUploadPausedNoWifi)
}

@available(iOS 17, *)
#Preview("Paused: Internet") {
    return BackupProgressViewPreviewViewController(state: .attachmentUploadPausedNoInternet)
}

@available(iOS 17, *)
#Preview("Paused: Battery") {
    return BackupProgressViewPreviewViewController(state: .attachmentUploadPausedLowBattery)
}

@available(iOS 17, *)
#Preview("Paused: Low Power Mode") {
    return BackupProgressViewPreviewViewController(state: .attachmentUploadPausedLowPowerMode)
}

@available(iOS 17, *)
#Preview("Complete") {
    return BackupProgressViewPreviewViewController(state: .complete)
}

@available(iOS 17, *)
#Preview("Nil") {
    return BackupProgressViewPreviewViewController(state: nil)
}

#endif
