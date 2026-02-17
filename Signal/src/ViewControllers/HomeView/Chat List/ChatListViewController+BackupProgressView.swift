//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import PureLayout
import SignalServiceKit
import UIKit

class CLVBackupProgressView {

    private struct State {
        var updateStreamTasks: [Task<Void, Never>] = []

        var isVisible: Bool = false
        var deviceSleepBlock: DeviceSleepBlockObject?

        var lastUploadTrackerUpdate: BackupAttachmentUploadTracker.UploadUpdate?
        var lastExportJobUpdate: BackupExportJobRunnerUpdate?
    }

    private let backupAttachmentUploadTracker: BackupAttachmentUploadTracker
    private let backupExportJobRunner: BackupExportJobRunner
    private let db: DB
    private let deviceSleepManager: DeviceSleepManager

    weak var chatListViewController: ChatListViewController?
    let backupProgressViewCell: UITableViewCell

    private let backupProgressView: BackupProgressView
    private let state: AtomicValue<State>

    init() {
        self.backupAttachmentUploadTracker = AppEnvironment.shared.backupAttachmentUploadTracker
        self.backupExportJobRunner = DependenciesBridge.shared.backupExportJobRunner
        self.db = DependenciesBridge.shared.db
        self.deviceSleepManager = DependenciesBridge.shared.deviceSleepManager.owsFailUnwrap("Missing DeviceSleepManager!")

        self.backupProgressViewCell = UITableViewCell()
        self.backupProgressViewCell.backgroundColor = .Signal.background
        self.backupProgressView = BackupProgressView(viewState: nil)
        self.state = AtomicValue(State(), lock: .init())

        self.backupProgressViewCell.contentView.addSubview(self.backupProgressView)
        self.backupProgressView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 12, vMargin: 12))
    }

    // MARK: -

    var shouldBeVisible: Bool {
        guard BuildFlags.Backups.chatListProgress else {
            return false
        }

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
        state.update { _state in
            guard _state.updateStreamTasks.isEmpty else { return }
            _state.updateStreamTasks = _startTracking()
        }
    }

    private func _startTracking() -> [Task<Void, Never>] {
        return [
            Task { @MainActor [weak self, backupAttachmentUploadTracker] in
                for await uploadTrackerUpdate in backupAttachmentUploadTracker.updates() {
                    guard let self else { return }

                    state.update { _state in
                        _state.lastUploadTrackerUpdate = uploadTrackerUpdate
                        self.setViewStateForState(state: &_state)
                    }
                }
            },
            Task { @MainActor [weak self, backupExportJobRunner] in
                for await exportJobUpdate in backupExportJobRunner.updates() {
                    guard let self else { return }

                    state.update { _state in
                        _state.lastExportJobUpdate = exportJobUpdate
                        self.setViewStateForState(state: &_state)
                    }
                }
            },
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
        switch state.lastExportJobUpdate {
        case .progress(let sequentialProgress):
            switch sequentialProgress.currentStep {
            case .backupFileExport, .backupFileUpload:
                let percentExportCompleted = sequentialProgress.progress(for: .backupFileExport)?.percentComplete ?? 0
                let percentUploadCompleted = sequentialProgress.progress(for: .backupFileUpload)?.percentComplete ?? 0
                let percentComplete = (0.95 * percentExportCompleted) + (0.05 * percentUploadCompleted)
                return .backupFilePreparation(percentComplete: percentComplete)
            case .attachmentUpload, .attachmentProcessing:
                break
            }
        case nil, .completion:
            break
        }

        if let lastUploadTrackerUpdate = state.lastUploadTrackerUpdate {
            switch lastUploadTrackerUpdate.state {
            case .running:
                return .attachmentUploadRunning(
                    bytesUploaded: lastUploadTrackerUpdate.bytesUploaded,
                    totalBytesToUpload: lastUploadTrackerUpdate.totalBytesToUpload,
                )
            case .pausedLowBattery:
                return .attachmentUploadPausedLowBattery
            case .pausedLowPowerMode:
                return .attachmentUploadPausedLowPowerMode
            case .pausedNeedsWifi:
                return .attachmentUploadPausedNoWifi
            case .pausedNeedsInternet:
                return .attachmentUploadPausedNoInternet
            }
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
        case .failed: false
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
}

// MARK: -

private class BackupProgressView: UIView {

    enum ViewState: Equatable, Identifiable {
        case backupFilePreparation(percentComplete: Float)
        case attachmentUploadRunning(bytesUploaded: UInt64, totalBytesToUpload: UInt64)
        case attachmentUploadPausedNoWifi
        case attachmentUploadPausedNoInternet
        case attachmentUploadPausedLowBattery
        case attachmentUploadPausedLowPowerMode
        case complete
        case failed

        var id: String {
            return switch self {
            case .backupFilePreparation: "backupFilePreparation"
            case .attachmentUploadRunning: "attachmentUploadRunning"
            case .attachmentUploadPausedNoWifi: "attachmentUploadPausedNoWifi"
            case .attachmentUploadPausedNoInternet: "attachmentUploadPausedNoInternet"
            case .attachmentUploadPausedLowBattery: "attachmentUploadPausedLowBattery"
            case .attachmentUploadPausedLowPowerMode: "attachmentUploadPausedLowPowerMode"
            case .complete: "complete"
            case .failed: "failed"
            }
        }
    }

    var viewState: ViewState? {
        didSet {
            configureSubviewsForCurrentState()
        }
    }

    // MARK: -

    private static func configure(label: UILabel, color: UIColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        label.font = .dynamicTypeSubheadline
        label.textColor = color
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
    }

    private let leadingAccessoryImageView = UIImageView()

    private let labelStackView = UIStackView()
    private let titleLabel = UILabel()
    private let progressLabel = UILabel()

    /// A container for the various trailingAccessory views we might display. A
    /// stack view so we can use `isHidden = true` to make subviews take up zero
    /// space.
    private let trailingAccessoryContainerView = UIStackView()
    private let trailingAccessorySpacerView = UIView()
    private let trailingAccessoryRunningArcView = ArcView()
    private let trailingAccessoryPausedWifiResumeButton = UIButton()
    private let trailingAccessoryPausedNoInternetLabel = UILabel()
    private let trailingAccessoryPausedLowBatteryLabel = UILabel()
    private let trailingAccessoryPausedLowPowerModeLabel = UILabel()
    private let trailingAccessoryCompleteDismissButton = UIButton()
    private let trailingAccessoryFailedDetailsButton = UIButton()

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
        labelStackView.axis = .vertical
        labelStackView.spacing = 4

        labelStackView.addArrangedSubview(titleLabel)
        Self.configure(label: titleLabel, color: .Signal.label)

        labelStackView.addArrangedSubview(progressLabel)
        Self.configure(label: progressLabel, color: .Signal.secondaryLabel)

        addSubview(trailingAccessoryContainerView)
        trailingAccessoryContainerView.alignment = .trailing
        trailingAccessoryContainerView.translatesAutoresizingMaskIntoConstraints = false

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessorySpacerView)
        trailingAccessorySpacerView.translatesAutoresizingMaskIntoConstraints = false

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryRunningArcView)
        trailingAccessoryRunningArcView.translatesAutoresizingMaskIntoConstraints = false

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedWifiResumeButton)
        trailingAccessoryPausedWifiResumeButton.translatesAutoresizingMaskIntoConstraints = false
        trailingAccessoryPausedWifiResumeButton.setTitle(
            "Resume",
            for: .normal,
        )
        trailingAccessoryPausedWifiResumeButton.setTitleColor(.Signal.label, for: .normal)
        trailingAccessoryPausedWifiResumeButton.titleLabel?.font = .dynamicTypeSubheadline.semibold()
        trailingAccessoryPausedWifiResumeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        trailingAccessoryPausedWifiResumeButton.addAction(
            UIAction { [weak self] _ in
                self?.didTapPausedWifiResumeButton()
            },
            for: .touchUpInside,
        )

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryCompleteDismissButton)
        trailingAccessoryCompleteDismissButton.translatesAutoresizingMaskIntoConstraints = false
        trailingAccessoryCompleteDismissButton.setImage(.x, animated: false)
        trailingAccessoryCompleteDismissButton.tintColor = .Signal.secondaryLabel
        trailingAccessoryCompleteDismissButton.addAction(
            UIAction { [weak self] _ in
                self?.didTapDismissButton()
            },
            for: .touchUpInside,
        )

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedNoInternetLabel)
        Self.configure(label: trailingAccessoryPausedNoInternetLabel, color: .Signal.secondaryLabel)
        trailingAccessoryPausedNoInternetLabel.text = "No Internet…"

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedLowBatteryLabel)
        Self.configure(label: trailingAccessoryPausedLowBatteryLabel, color: .Signal.secondaryLabel)
        trailingAccessoryPausedLowBatteryLabel.text = "Low Battery…"

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryPausedLowPowerModeLabel)
        Self.configure(label: trailingAccessoryPausedLowPowerModeLabel, color: .Signal.secondaryLabel)
        trailingAccessoryPausedLowPowerModeLabel.text = "Low Power Mode…"

        trailingAccessoryContainerView.addArrangedSubview(trailingAccessoryFailedDetailsButton)
        trailingAccessoryFailedDetailsButton.translatesAutoresizingMaskIntoConstraints = false
        trailingAccessoryFailedDetailsButton.setTitle(
            "See Details",
            for: .normal,
        )
        trailingAccessoryFailedDetailsButton.setTitleColor(.Signal.label, for: .normal)
        trailingAccessoryFailedDetailsButton.titleLabel?.font = .dynamicTypeSubheadline.semibold()
        trailingAccessoryFailedDetailsButton.titleLabel?.adjustsFontForContentSizeCategory = true
        trailingAccessoryFailedDetailsButton.addAction(
            UIAction { [weak self] _ in
                self?.didTapFailedDetailsButton()
            },
            for: .touchUpInside,
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
        case .failed:
            leadingAccessoryImageView.image = .errorCircle
            leadingAccessoryImageView.tintColor = .Signal.orange
        }

        // Labels
        let titleLabelText: String
        var progressLabelText: String?
        switch viewState {
        case .backupFilePreparation(let percentComplete):
            titleLabelText = "Preparing backup"
            progressLabelText = percentComplete.formatted(.owsPercent())
        case .attachmentUploadRunning(let bytesUploaded, let totalBytesToUpload):
            titleLabelText = "Uploading backup"
            progressLabelText = String(
                format: "%1$@ of %2$@",
                bytesUploaded.formatted(.owsByteCount()),
                totalBytesToUpload.formatted(.owsByteCount()),
            )
        case .attachmentUploadPausedNoWifi:
            titleLabelText = "Waiting for Wi-Fi"
        case .attachmentUploadPausedNoInternet:
            titleLabelText = "Backup paused"
        case .attachmentUploadPausedLowBattery:
            titleLabelText = "Backup paused"
        case .attachmentUploadPausedLowPowerMode:
            titleLabelText = "Backup paused"
        case .complete:
            titleLabelText = "Backup complete"
        case .failed:
            titleLabelText = "Backup failed"
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
        case .failed:
            trailingAccessoryView = trailingAccessoryFailedDetailsButton
        case nil:
            trailingAccessoryView = nil
        }

        // Hide all but at most one trailingAccessory view.
        for view in trailingAccessoryContainerView.arrangedSubviews {
            if view == trailingAccessoryView || view == trailingAccessorySpacerView {
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

    // MARK: -

    private func didTapDismissButton() {
        // TODO: Implement
        print(#function)
    }

    private func didTapPausedWifiResumeButton() {
        // TODO: Implement
        print(#function)
    }

    private func didTapFailedDetailsButton() {
        // TODO: Implement
        print(#function)
    }
}

// MARK: -

extension ChatListViewController {
    func handleBackupProgressViewTapped() {
        // TODO: Implement
        print(#function)
    }
}

// MARK: -

#if DEBUG

private class BackupProgressViewPreviewViewController: UIViewController {
    private let state: BackupProgressView.ViewState?

    init(state: BackupProgressView.ViewState?) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let progressView = BackupProgressView(viewState: state)
        view.addSubview(progressView)
        progressView.autoPinEdgesToSuperviewSafeArea(
            with: UIEdgeInsets(margin: 16),
            excludingEdge: .bottom,
        )
    }
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
#Preview("Failed") {
    return BackupProgressViewPreviewViewController(state: .failed)
}

@available(iOS 17, *)
#Preview("Nil") {
    return BackupProgressViewPreviewViewController(state: nil)
}

#endif
