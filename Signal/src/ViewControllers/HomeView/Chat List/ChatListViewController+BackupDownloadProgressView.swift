//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
public import SignalServiceKit
import SignalUI

public class CLVBackupDownloadProgressView {

    private struct State {
        var didDismissDownloadBanner: Bool = false
        var downloadCompleteBannerByteCount: UInt64?
        var deviceSleepBlock: DeviceSleepBlockObject?

        var latestDownloadUpdate: BackupAttachmentDownloadTracker.DownloadUpdate?
    }

    private let state: AtomicValue<State>

    public weak var chatListViewController: ChatListViewController?
    public let backupDownloadProgressViewCell: UITableViewCell
    private let backupAttachmentDownloadProgressView: BackupAttachmentDownloadProgressView

    private let backupAttachmentDownloadTracker: BackupAttachmentDownloadTracker
    private let backupAttachmentDownloadStore: BackupAttachmentDownloadStore
    private let backupSettingsStore: BackupSettingsStore
    private let db: DB
    private let deviceSleepManager: DeviceSleepManager

    init() {
        AssertIsOnMainThread()

        guard let deviceSleepManager = DependenciesBridge.shared.deviceSleepManager else {
            owsFail("Unexpectedly missing device sleep manager in main app!")
        }

        state = AtomicValue(State(), lock: .init())

        self.backupAttachmentDownloadTracker = AppEnvironment.shared.backupAttachmentDownloadTracker
        self.backupAttachmentDownloadStore = DependenciesBridge.shared.backupAttachmentDownloadStore
        self.backupSettingsStore = BackupSettingsStore()
        self.db = DependenciesBridge.shared.db
        self.deviceSleepManager = deviceSleepManager

        backupAttachmentDownloadProgressView = BackupAttachmentDownloadProgressView(
            backupAttachmentDownloadQueueStatusReporter: DependenciesBridge.shared.backupAttachmentDownloadQueueStatusManager,
            backupAttachmentDownloadStore: backupAttachmentDownloadStore,
            backupSettingsStore: backupSettingsStore,
            db: db,
        )

        backupDownloadProgressViewCell = UITableViewCell()
        backupDownloadProgressViewCell.backgroundColor = .Signal.background
        backupDownloadProgressViewCell.contentView.addSubview(backupAttachmentDownloadProgressView)
        backupAttachmentDownloadProgressView.autoPinEdgesToSuperviewEdges()

        backupAttachmentDownloadProgressView.clvProgressView = self
    }

    var shouldBeVisible: Bool {
        return downloadProgressViewState() != nil
    }

    // MARK: -

    @MainActor
    func trackDownloads() {
        Task { [weak self, backupAttachmentDownloadTracker] in
            for await downloadUpdate in backupAttachmentDownloadTracker.updates() {
                guard let self else { return }
                onDownloadUpdate(downloadUpdate)
            }
        }
    }

    @MainActor
    private func onDownloadUpdate(_ downloadUpdate: BackupAttachmentDownloadTracker.DownloadUpdate) {
        let downloadUpdateStateChanged = state.update {
            let oldLatestDownloadUpdate = $0.latestDownloadUpdate
            $0.latestDownloadUpdate = downloadUpdate

            return oldLatestDownloadUpdate?.state != downloadUpdate.state
        }

        if downloadUpdateStateChanged {
            // On our first update, and any subsequent time the state of
            // downloads changes, reload our ancillary data. This helps
            // us ensure we show the right view state when the queue is
            // empty while avoiding runaway DB reads.
            loadAncillaryBannerState()
        }

        updateViewState()
    }

    private func loadAncillaryBannerState() {
        db.read { tx in
            let didDismissDownloadBanner = backupAttachmentDownloadStore.getDidDismissDownloadCompleteBanner(tx: tx)
            let downloadCompleteBannerByteCount = backupAttachmentDownloadStore.getDownloadCompleteBannerByteCount(tx: tx)

            state.update {
                $0.didDismissDownloadBanner = didDismissDownloadBanner
                $0.downloadCompleteBannerByteCount = downloadCompleteBannerByteCount
            }
        }
    }

    @MainActor
    private func updateViewState() {
        let viewState: BackupAttachmentDownloadProgressView.State? = downloadProgressViewState()

        let oldViewState = backupAttachmentDownloadProgressView.state
        backupAttachmentDownloadProgressView.state = viewState

        if (oldViewState == nil) != (viewState == nil) {
            DispatchQueue.main.async { [weak self] in
                self?.chatListViewController?.loadCoordinator.loadIfNecessary()
            }
        }

        manageDeviceSleepBlock(viewState: viewState)
    }

    @MainActor
    fileprivate func didTapDismiss() {
        db.write { tx in
            self.backupAttachmentDownloadStore.setDidDismissDownloadCompleteBanner(tx: tx)
        }

        // Reload state and update the view, so we learn that the banner is now
        // dismissed.
        loadAncillaryBannerState()
        updateViewState()
    }

    // MARK: -

    @MainActor
    func willAppear() {
        manageDeviceSleepBlock(viewState: backupAttachmentDownloadProgressView.state)
    }

    @MainActor
    func didDisappear() {
        // Force-drop the sleep block if we're disappearing.
        manageDeviceSleepBlock(viewState: nil)
    }

    @MainActor
    private func manageDeviceSleepBlock(viewState: BackupAttachmentDownloadProgressView.State?) {
        state.update { state in
            _manageDeviceSleepBlock(state: &state, viewState: viewState)
        }
    }

    @MainActor
    private func _manageDeviceSleepBlock(
        state: inout State,
        viewState: BackupAttachmentDownloadProgressView.State?,
    ) {
        switch viewState {
        case nil, .complete:
            if let deviceSleepBlock = state.deviceSleepBlock.take() {
                deviceSleepManager.removeBlock(blockObject: deviceSleepBlock)
            }
        case .restoring, .wifiNotReachable, .paused, .outOfDiskSpace:
            if state.deviceSleepBlock == nil {
                let deviceSleepBlock = DeviceSleepBlockObject(blockReason: "BackupAttachmentDownloadProgressView")
                state.deviceSleepBlock = deviceSleepBlock
                deviceSleepManager.addBlock(blockObject: deviceSleepBlock)
            }
        }
    }

    // MARK: -

    func measureHeight(width: CGFloat) -> CGFloat {
        BackupAttachmentDownloadProgressView.measureHeight(
            inWidth: width,
            state: downloadProgressViewState(),
        )
    }

    private func downloadProgressViewState() -> BackupAttachmentDownloadProgressView.State? {
        let state = state.get()

        guard let latestDownloadUpdate = state.latestDownloadUpdate else {
            return nil
        }

        switch latestDownloadUpdate.state {
        case .suspended, .notRegisteredAndReady, .appBackgrounded:
            return nil
        case .empty:
            if
                !state.didDismissDownloadBanner,
                let byteCount = state.downloadCompleteBannerByteCount
            {
                return .complete(size: byteCount)
            } else {
                return nil
            }
        case .running:
            return .restoring(
                bytesDownloaded: latestDownloadUpdate.bytesDownloaded,
                totalBytesToDownload: latestDownloadUpdate.totalBytesToDownload,
                percentageDownloaded: latestDownloadUpdate.percentageDownloaded,
            )
        case .pausedLowBattery:
            return .paused(reason: .lowBattery)
        case .pausedLowPowerMode:
            return .paused(reason: .lowPowerMode)
        case .pausedNeedsWifi:
            return .wifiNotReachable
        case .pausedNeedsInternet:
            return .paused(reason: .notReachable)
        case .outOfDiskSpace(let bytesRequired):
            return .outOfDiskSpace(spaceRequired: bytesRequired)
        }
    }
}

// MARK: -

extension ChatListViewController {
    func handleBackupDownloadProgressViewTapped() {
        let db = DependenciesBridge.shared.db
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager

        let isPrimaryDevice = db.read { tx in
            tsAccountManager.registrationState(tx: tx).isPrimaryDevice ?? false
        }

        if isPrimaryDevice {
            showAppSettings(mode: .backups())
        } else {
            showCancelBackupDownloadsHeroSheet()
        }
    }

    private func showCancelBackupDownloadsHeroSheet() {
        let cancelDownloadsSheet = HeroSheetViewController(
            hero: .image(.backupsLogo),
            title: OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_1_TITLE",
                comment: "Title for a sheet allowing users to cancel an in-progress media restore.",
            ),
            body: OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_1_BODY",
                comment: "Body for a sheet allowing users to cancel an in-progress media restore.",
            ),
            primaryButton: .dismissing(title: OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_1_PRIMARY_BUTTON",
                comment: "Button for a sheet allowing users to cancel an in-progress media restore.",
            )),
            secondaryButton: HeroSheetViewController.Button(
                title: OWSLocalizedString(
                    "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_1_SECONDARY_BUTTON",
                    comment: "Button for a sheet allowing users to cancel an in-progress media restore.",
                ),
                style: .secondaryDestructive,
                action: .custom({ sheet in
                    sheet.dismiss(animated: true) { [weak self] in
                        self?.showCancelBackupDownloadsConfirmationActionSheet()
                    }
                }),
            ),
        )

        present(cancelDownloadsSheet, animated: true)
    }

    private func showCancelBackupDownloadsConfirmationActionSheet() {
        let backupSettingsStore = BackupSettingsStore()
        let db = DependenciesBridge.shared.db

        let confirmationActionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_2_TITLE",
                comment: "Title for a sheet allowing users to cancel an in-progress media restore.",
            ),
            message: OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_2_MESSAGE",
                comment: "Message for a sheet allowing users to cancel an in-progress media restore.",
            ),
        )
        confirmationActionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_2_PRIMARY_BUTTON",
                comment: "Button for a sheet allowing users to cancel an in-progress media restore.",
            ),
            style: .default,
        ))
        confirmationActionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_CANCEL_RESTORE_SHEET_2_SECONDARY_BUTTON",
                comment: "Button for a sheet allowing users to cancel an in-progress media restore.",
            ),
            style: .destructive,
            handler: { _ in
                db.write { tx in
                    backupSettingsStore.setIsBackupDownloadQueueSuspended(true, tx: tx)
                }
            },
        ))

        confirmationActionSheet.isCancelable = true
        presentActionSheet(confirmationActionSheet)
    }
}

// MARK: -

private class BackupAttachmentDownloadProgressView: UIView {

    enum State {
        case restoring(
            bytesDownloaded: UInt64,
            totalBytesToDownload: UInt64,
            percentageDownloaded: Float,
        )
        case wifiNotReachable
        case paused(reason: PauseReason)
        case outOfDiskSpace(spaceRequired: UInt64)
        case complete(size: UInt64)

        enum PauseReason {
            case notReachable
            case lowBattery
            case lowPowerMode
        }
    }

    weak var clvProgressView: CLVBackupDownloadProgressView?

    var state: State? {
        didSet {
            render()
        }
    }

    private let backupAttachmentDownloadQueueStatusReporter: BackupAttachmentDownloadQueueStatusReporter!
    private let backupAttachmentDownloadStore: BackupAttachmentDownloadStore!
    private let backupSettingsStore: BackupSettingsStore!
    private let db: DB!

    init(
        backupAttachmentDownloadQueueStatusReporter: BackupAttachmentDownloadQueueStatusReporter,
        backupAttachmentDownloadStore: BackupAttachmentDownloadStore,
        backupSettingsStore: BackupSettingsStore,
        db: DB,
    ) {
        self.backupAttachmentDownloadQueueStatusReporter = backupAttachmentDownloadQueueStatusReporter
        self.backupAttachmentDownloadStore = backupAttachmentDownloadStore
        self.backupSettingsStore = backupSettingsStore
        self.db = db
        super.init(frame: .zero)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(render),
            name: .themeDidChange,
            object: nil,
        )

        initialRender()
    }

    fileprivate init(forPreview: (), state: State) {
        self.backupAttachmentDownloadQueueStatusReporter = nil
        self.backupAttachmentDownloadStore = nil
        self.backupSettingsStore = nil
        self.db = nil

        self.state = state

        super.init(frame: .zero)

        initialRender()
    }

    @available(*, unavailable, message: "use other constructor instead.")
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable, message: "use other constructor instead.")
    override init(frame: CGRect) {
        fatalError("init(frame:) has not been implemented")
    }

    // MARK: - Rendering

    private lazy var backgroundView: UIView = {
        let view = UIView()
        view.layer.cornerRadius = Constants.spacing
        return view
    }()

    private lazy var iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = Constants.titleLabelFont
        label.adjustsFontSizeToFitWidth = true
        label.textAlignment = .left
        label.numberOfLines = 0
        return label
    }()

    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = Constants.subtitleLabelFont
        label.textColor = UIColor.Signal.secondaryLabel
        label.adjustsFontSizeToFitWidth = true
        label.textAlignment = .right
        label.numberOfLines = 0
        return label
    }()

    private lazy var diskSpaceLabel: UILabel = {
        let label = UILabel()
        label.font = Constants.diskSpaceLabelFont
        label.adjustsFontSizeToFitWidth = true
        label.textAlignment = .left
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private lazy var progressIndicatorView = ArcView()

    private lazy var dismissButton: OWSButton = {
        let button = OWSButton(imageName: "x-28", tintColor: UIColor.Signal.secondaryLabel) { [weak self] in
            guard let self else { return }

            switch state {
            case .complete:
                clvProgressView?.didTapDismiss()
            case nil, .restoring, .wifiNotReachable, .paused, .outOfDiskSpace:
                return
            }
        }
        return button
    }()

    private lazy var detailsButton: OWSButton = {
        let button = OWSButton(
            title: Constants.detailsButtonText,
        ) { [weak self] in
            self?.didTapDetails()
        }
        button.setTitleColor(UIColor.Signal.label, for: .normal)
        button.titleLabel?.font = Constants.detailsButtonFont
        button.isHidden = true
        return button
    }()

    private lazy var resumeButton: OWSButton = {
        let button = OWSButton(
            title: Constants.resumeButtonText,
        ) { [weak self] in
            self?.didTapResume()
        }
        button.setTitleColor(UIColor.Signal.label, for: .normal)
        button.titleLabel?.font = Constants.detailsButtonFont
        button.isHidden = true
        return button
    }()

    private func initialRender() {
        self.addSubview(backgroundView)
        backgroundView.autoPinEdgesToSuperviewEdges(with: .init(margin: Constants.spacing))
        backgroundView.backgroundColor = UIColor.Signal.secondaryBackground

        backgroundView.addSubview(iconView)

        backgroundView.addSubview(titleLabel)
        backgroundView.addSubview(subtitleLabel)
        backgroundView.addSubview(progressIndicatorView)

        backgroundView.addSubview(dismissButton)

        backgroundView.addSubview(diskSpaceLabel)
        backgroundView.addSubview(detailsButton)

        backgroundView.addSubview(resumeButton)

        render()
    }

    @objc
    private func render() {
        if state == nil {
            return
        }
        renderIcon()
        titleLabel.text = Self.titleLabelText(state: state)
        subtitleLabel.text = Self.subtitleLabelText(state: state)
        renderProgressIndicator()
        diskSpaceLabel.text = Self.diskSpaceLabelText(state: state)
        renderResumeButton()
        renderDetailsButton()
        renderDismissButton()
        layout()
    }

    override var bounds: CGRect {
        get { super.bounds }
        set {
            super.bounds = newValue
            layout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout()
    }

    private struct Frames {
        let state: State?
        let width: CGFloat
        var backgroundView: CGRect = .zero
        // All below here are in backgroundView's frame
        var iconView: CGRect = .zero
        // Nil = hidden
        var progressIndicatorView: CGRect?
        var titleLabel: CGRect?
        var subtitleLabel: (CGRect, NSTextAlignment)?
        var diskSpaceLabel: CGRect?
        var detailsButton: CGRect?
        var dismissButton: CGRect?
        var resumeButton: CGRect?
    }

    private func layout() {
        let frames = Self.measureFrames(inWidth: bounds.width, state: state)
        backgroundView.frame = frames.backgroundView
        iconView.frame = frames.iconView
        progressIndicatorView.isHidden = frames.progressIndicatorView == nil
        frames.progressIndicatorView.map { progressIndicatorView.frame = $0 }
        titleLabel.isHidden = frames.titleLabel == nil
        frames.titleLabel.map { titleLabel.frame = $0 }
        subtitleLabel.isHidden = frames.subtitleLabel == nil
        frames.subtitleLabel.map { frame, textAlignment in
            subtitleLabel.frame = frame
            subtitleLabel.textAlignment = textAlignment
        }
        diskSpaceLabel.isHidden = frames.diskSpaceLabel == nil
        frames.diskSpaceLabel.map { diskSpaceLabel.frame = $0 }
        detailsButton.isHidden = frames.detailsButton == nil
        frames.detailsButton.map { detailsButton.frame = $0 }
        dismissButton.isHidden = frames.dismissButton == nil
        frames.dismissButton.map { dismissButton.frame = $0 }
        resumeButton.isHidden = frames.resumeButton == nil
        frames.resumeButton.map { resumeButton.frame = $0 }
    }

    static func measureHeight(
        inWidth width: CGFloat,
        state: State?,
    ) -> CGFloat {
        let frames = measureFrames(inWidth: width, state: state)
        return frames.backgroundView.height + (Constants.spacing * 2)
    }

    private static func measureFrames(
        inWidth width: CGFloat,
        state: State?,
    ) -> Frames {
        var frames = Frames(state: state, width: width)

        // Subtract the background view's inset
        frames.backgroundView.x = Constants.spacing
        frames.backgroundView.y = Constants.spacing
        frames.backgroundView.width = width - (Constants.spacing * 2)

        // First we do x axis; ignore y axis values.
        // (except fixed heights which we can just do now).
        frames.iconView.x = Constants.spacing
        frames.iconView.width = Constants.iconSize
        frames.iconView.height = Constants.iconSize

        switch state {
        case .restoring:
            frames.progressIndicatorView = .zero
            frames.progressIndicatorView?.x = frames.backgroundView.width - Constants.spacing - Constants.iconSize
            frames.progressIndicatorView?.width = Constants.iconSize
            frames.progressIndicatorView?.height = Constants.iconSize
        case .complete:
            frames.dismissButton = .zero
            frames.dismissButton?.x = frames.backgroundView.width - Constants.spacing - Constants.iconSize
            frames.dismissButton?.width = Constants.iconSize
            frames.dismissButton?.height = Constants.iconSize
        case .wifiNotReachable:
            let resumeButtonSize = (Constants.resumeButtonText as NSString).boundingRect(
                with: .square(.greatestFiniteMagnitude),
                options: [.usesFontLeading, .usesLineFragmentOrigin],
                attributes: [.font: Constants.resumeButtonFont],
                context: nil,
            )
            frames.resumeButton = .zero
            frames.resumeButton?.x = frames.backgroundView.width - Constants.spacing - resumeButtonSize.width
            frames.resumeButton?.width = resumeButtonSize.width
            frames.resumeButton?.height = resumeButtonSize.height
        case nil, .paused, .outOfDiskSpace:
            break
        }

        switch state {
        case .restoring, .wifiNotReachable, .paused, .complete:
            measureTitleSubtitleLabel(&frames)
        case .outOfDiskSpace:
            measureOutOfDiskSpaceViews(&frames)
        case nil:
            break
        }

        // Now that widths were determined and height of the background view
        // was set, we can centerY the relevant frames.
        frames.iconView.y = (frames.backgroundView.height / 2) - (frames.iconView.height / 2)
        let centerYFrames: [WritableKeyPath<Frames, CGRect?>] = [
            \.progressIndicatorView,
            \.dismissButton,
            \.detailsButton,
            \.resumeButton,
        ]
        for frameKeyPath in centerYFrames {
            guard var frame = frames[keyPath: frameKeyPath] else { continue }
            frame.y = (frames.backgroundView.height / 2) - (frame.height / 2)
            frames[keyPath: frameKeyPath] = frame
        }
        return frames
    }

    private static func measureTitleSubtitleLabel(_ frames: inout Frames) {
        let labelsMinXBound = frames.iconView.maxX + Constants.spacing
        let labelsMaxXBounds: [CGFloat?] = [
            frames.progressIndicatorView?.minX,
            frames.dismissButton?.minX,
            frames.resumeButton?.minX,
            frames.backgroundView.width,
        ]
        let labelsMaxXBound = labelsMaxXBounds.compacted().min()! - Constants.spacing
        let labelsAvailableWidth = labelsMaxXBound - labelsMinXBound

        var titleLabelSize = ((titleLabelText(state: frames.state) ?? "") as NSString).boundingRect(
            with: CGSize(width: labelsAvailableWidth, height: .greatestFiniteMagnitude),
            options: [.usesFontLeading, .usesLineFragmentOrigin],
            attributes: [.font: Constants.titleLabelFont],
            context: nil,
        )
        titleLabelSize.width = min(titleLabelSize.width, labelsAvailableWidth)

        var subtitleLabelSize = ((subtitleLabelText(state: frames.state) ?? "") as NSString).boundingRect(
            with: CGSize(width: labelsAvailableWidth, height: .greatestFiniteMagnitude),
            options: [.usesFontLeading, .usesLineFragmentOrigin],
            attributes: [.font: Constants.subtitleLabelFont],
            context: nil,
        )
        subtitleLabelSize.width = min(subtitleLabelSize.width, labelsAvailableWidth)

        let subtitleLabelAvailableWidth = labelsAvailableWidth - titleLabelSize.width - Constants.spacing

        if
            subtitleLabelSize.width > 0,
            subtitleLabelSize.width > subtitleLabelAvailableWidth
        {
            // We go to two lines
            let labelsHeight = titleLabelSize.height + subtitleLabelSize.height
            frames.backgroundView.height = max(
                labelsHeight,
                frames.iconView.height,
                frames.dismissButton?.height ?? 0,
                frames.progressIndicatorView?.height ?? 0,
            ) + (Constants.spacing * 2)
            frames.titleLabel = CGRect(
                x: frames.iconView.maxX + Constants.spacing,
                y: (frames.backgroundView.height / 2) - (labelsHeight / 2),
                width: titleLabelSize.width,
                height: titleLabelSize.height,
            )
            frames.subtitleLabel = (
                CGRect(
                    x: frames.titleLabel!.minX,
                    y: frames.titleLabel!.maxY,
                    width: subtitleLabelSize.width,
                    height: subtitleLabelSize.height,
                ),
                .left,
            )
        } else {
            // Just one line
            let labelsHeight = max(titleLabelSize.height, subtitleLabelSize.height)
            frames.backgroundView.height = max(
                labelsHeight,
                frames.iconView.height,
                frames.dismissButton?.height ?? 0,
                frames.progressIndicatorView?.height ?? 0,
            ) + (Constants.spacing * 2)
            frames.titleLabel = CGRect(
                x: frames.iconView.maxX + Constants.spacing,
                y: (frames.backgroundView.height / 2) - (titleLabelSize.height / 2),
                width: titleLabelSize.width,
                height: titleLabelSize.height,
            )
            let subtitleMinX = frames.titleLabel!.maxX + Constants.spacing
            frames.subtitleLabel = (
                CGRect(
                    x: subtitleMinX,
                    y: (frames.backgroundView.height / 2) - (subtitleLabelSize.height / 2),
                    width: labelsMaxXBound - subtitleMinX,
                    height: subtitleLabelSize.height,
                ),
                .right,
            )
        }
    }

    private static func measureOutOfDiskSpaceViews(_ frames: inout Frames) {
        let detailsButtonSize = (Constants.detailsButtonText as NSString).boundingRect(
            with: .square(.greatestFiniteMagnitude),
            options: [.usesFontLeading, .usesLineFragmentOrigin],
            attributes: [.font: Constants.detailsButtonFont],
            context: nil,
        )
        frames.detailsButton = .zero
        frames.detailsButton?.x = frames.backgroundView.width - Constants.spacing - detailsButtonSize.width
        frames.detailsButton?.width = detailsButtonSize.width
        frames.detailsButton?.height = detailsButtonSize.height

        let availableLabelWidth =
            (frames.detailsButton!.minX - Constants.spacing)
                - (frames.iconView.maxX + Constants.spacing)
        let diskSpaceLabelSize = ((diskSpaceLabelText(state: frames.state) ?? "") as NSString).boundingRect(
            with: CGSize(width: availableLabelWidth, height: .greatestFiniteMagnitude),
            options: [.usesFontLeading, .usesLineFragmentOrigin],
            attributes: [.font: Constants.diskSpaceLabelFont],
            context: nil,
        )

        frames.backgroundView.height = max(
            frames.iconView.height,
            diskSpaceLabelSize.height,
            detailsButtonSize.height,
        ) + Constants.spacing * 2
        frames.diskSpaceLabel = CGRect(
            x: frames.iconView.maxX + Constants.spacing,
            y: (frames.backgroundView.height / 2) - (diskSpaceLabelSize.height / 2),
            width: diskSpaceLabelSize.width,
            height: diskSpaceLabelSize.height,
        )
    }

    private func renderIcon() {
        let (iconName, tintColor): (String, UIColor) = switch state {
        case .restoring, .wifiNotReachable, .paused, nil:
            ("backup-bold", UIColor.Signal.label)
        case .outOfDiskSpace:
            ("backup-error-bold", UIColor.Signal.orange)
        case .complete:
            ("check-circle", UIColor.Signal.ultramarine)
        }
        iconView.setTemplateImage(UIImage(named: iconName), tintColor: tintColor)
    }

    private static func titleLabelText(state: State?) -> String? {
        return switch state {
        case .restoring:
            OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_TITLE",
                comment: "Title shown on chat list banner for restoring media from a backup",
            )
        case .wifiNotReachable:
            OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_WAITING_FOR_WIFI_TITLE",
                comment: "Title shown on chat list banner for restoring media from a backup when waiting for wifi",
            )
        case .paused:
            OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_PAUSED_TITLE",
                comment: "Title shown on chat list banner for restoring media from a backup when paused for some reason",
            )
        case .outOfDiskSpace:
            nil
        case .complete:
            OWSLocalizedString(
                "RESTORING_MEDIA_BANNER_FINISHED_TITLE",
                comment: "Title shown on chat list banner for restoring media from a backup is finished",
            )
        case nil:
            nil
        }
    }

    private static func subtitleLabelText(state: State?) -> String? {
        return switch state {
        case .restoring(let bytesDownloaded, let totalBytesToDownload, _) where totalBytesToDownload > 0:
            String(
                format: OWSLocalizedString(
                    "RESTORING_MEDIA_BANNER_PROGRESS_FORMAT",
                    comment: "Download progress for media from a backup. Embeds {{ %1$@ formatted number of bytes downloaded, e.g. '100 MB', %2$@ formatted total number of bytes to download, e.g. '3 GB' }}",
                ),
                formatByteSize(bytesDownloaded),
                formatByteSize(totalBytesToDownload),
            )
        case .restoring:
            nil
        case .wifiNotReachable:
            nil
        case .paused(let reason):
            switch reason {
            case .lowBattery:
                OWSLocalizedString(
                    "RESTORING_MEDIA_BANNER_PAUSED_BATTERY_SUBTITLE",
                    comment: "Subtitle shown on chat list banner for restoring media from a backup when paused because the device has low battery",
                )
            case .lowPowerMode:
                OWSLocalizedString(
                    "RESTORING_MEDIA_BANNER_PAUSED_LOW_POWER_MODE_SUBTITLE",
                    comment: "Subtitle shown on chat list banner for restoring media from a backup when paused because the device is in low power mode",
                )
            case .notReachable:
                OWSLocalizedString(
                    "RESTORING_MEDIA_BANNER_PAUSED_NOT_REACHABLE_SUBTITLE",
                    comment: "Subtitle shown on chat list banner for restoring media from a backup when paused because the device has no internet connection",
                )
            }
        case .outOfDiskSpace:
            nil
        case .complete(let size):
            formatByteSize(size)
        case nil:
            nil
        }
    }

    private func renderProgressIndicator() {
        switch state {
        case .restoring(_, _, let percentageDownloaded):
            progressIndicatorView.isHidden = false
            progressIndicatorView.percentComplete = percentageDownloaded
        case nil, .wifiNotReachable, .paused, .outOfDiskSpace, .complete:
            progressIndicatorView.isHidden = true
        }
    }

    private static func diskSpaceLabelText(state: State?) -> String? {
        return switch state {
        case .outOfDiskSpace(let spaceRequired):
            String(
                format: OWSLocalizedString(
                    "RESTORING_MEDIA_BANNER_DISK_SPACE_TITLE_FORMAT",
                    comment: "Title shown on chat list banner for restoring media from a backup when paused because the device has insufficient disk space. Embeds {{ %@ formatted number of bytes downloaded, e.g. '100 MB' }}",
                ),
                formatByteSize(spaceRequired),
            )
        case nil, .restoring, .wifiNotReachable, .paused, .complete:
            nil
        }
    }

    private func renderDetailsButton() {
        detailsButton.isHidden = switch state {
        case .outOfDiskSpace: false
        case nil, .restoring, .wifiNotReachable, .paused, .complete: true
        }
    }

    private func renderDismissButton() {
        dismissButton.isHidden = switch state {
        case .complete: false
        case nil, .restoring, .wifiNotReachable, .paused, .outOfDiskSpace: true
        }
    }

    private func renderResumeButton() {
        resumeButton.isHidden = switch state {
        case .wifiNotReachable: false
        case nil, .restoring, .paused, .outOfDiskSpace, .complete: true
        }
    }

    private static func formatByteSize(_ byteSize: UInt64) -> String {
        return OWSByteCountFormatStyle().format(byteSize)
    }

    private func didTapResume() {
        switch state {
        case nil, .restoring, .paused, .outOfDiskSpace, .complete:
            return
        case .wifiNotReachable:
            db.write { tx in
                backupSettingsStore.setShouldAllowBackupDownloadsOnCellular(true, tx: tx)
            }
        }
    }

    private func didTapDetails() {
        switch state {
        case .restoring, .wifiNotReachable, .paused, .complete, nil:
            return
        case .outOfDiskSpace(let spaceRequired):
            let spaceRequiredString = Self.formatByteSize(spaceRequired)
            var sheet: HeroSheetViewController?
            sheet = HeroSheetViewController(
                hero: .circleIcon(
                    icon: .backupErrorDisplayBold,
                    iconSize: 40,
                    tintColor: UIColor.Signal.orange,
                    backgroundColor: UIColor.color(rgbHex: 0xF9E4B6),
                ),
                title: String(
                    format: OWSLocalizedString(
                        "RESTORING_MEDIA_DISK_SPACE_SHEET_TITLE_FORMAT",
                        comment: "Title shown on a bottom sheet for restoring media from a backup when paused because the device has insufficient disk space. Embeds {{ %@ formatted number of bytes downloaded, e.g. '100 MB' }}",
                    ),
                    spaceRequiredString,
                ),
                body: String(
                    format: OWSLocalizedString(
                        "RESTORING_MEDIA_DISK_SPACE_SHEET_SUBTITLE_FORMAT",
                        comment: "Subtitle shown on a bottom sheet for restoring media from a backup when paused because the device has insufficient disk space. Embeds {{ %@ formatted number of bytes downloaded, e.g. '100 MB' }}",
                    ),
                    spaceRequiredString,
                ),
                primaryButton: .init(
                    title: OWSLocalizedString(
                        "ALERT_ACTION_ACKNOWLEDGE",
                        comment: "generic button text to acknowledge that the corresponding text was read.",
                    ),
                    action: { sheet in
                        // Clear previous out of space errors, so they can try
                        // again to download.
                        self.backupAttachmentDownloadQueueStatusReporter.checkAvailableDiskSpace(
                            clearPreviousOutOfSpaceErrors: true,
                        )
                        sheet.dismiss(animated: true)
                    },
                ),
                secondaryButton: .init(
                    title: OWSLocalizedString(
                        "RESTORING_MEDIA_DISK_SPACE_SHEET_SKIP_BUTTON",
                        comment: "Button to skip restoring media, shown on a bottom sheet for restoring media from a backup when paused because the device has insufficient disk space.",
                    ),
                    style: .secondary,
                    action: .custom({ [weak self] sheet in
                        sheet.dismiss(animated: true) {
                            self?.presentSkipRestoreSheet()
                        }
                    }),
                ),
            )
            CurrentAppContext().frontmostViewController()?.present(sheet!, animated: true)
            return
        }
    }

    private func presentSkipRestoreSheet() {
        let backupPlan = db.read { tx in
            backupSettingsStore.backupPlan(tx: tx)
        }

        let message: String = switch backupPlan {
        case .disabled, .disabling, .free, .paid, .paidAsTester:
            OWSLocalizedString(
                "RESTORING_MEDIA_DISK_SPACE_SKIP_SHEET_MESSAGE",
                comment: "Message shown on a bottom sheet to skip restoring media from a backup when paused because the device has insufficient disk space.",
            )
        case .paidExpiringSoon:
            OWSLocalizedString(
                "RESTORING_MEDIA_DISK_SPACE_SKIP_PAID_EXPIRING_SOON_SHEET_MESSAGE",
                comment: "Message shown on a bottom sheet to skip restoring media from a backup when paused because the device has insufficient disk space, and the user's paid subscription is expiring.",
            )
        }

        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "RESTORING_MEDIA_DISK_SPACE_SKIP_SHEET_TITLE",
                comment: "Title shown on a bottom sheet to skip restoring media from a backup when paused because the device has insufficient disk space.",
            ),
            message: message,
        )
        actionSheet.addAction(.init(
            title: OWSLocalizedString(
                "RESTORING_MEDIA_DISK_SPACE_SKIP_SHEET_SKIP_BUTTON",
                comment: "Button shown on a bottom sheet to skip restoring media from a backup when paused because the device has insufficient disk space.",
            ),
            style: .destructive,
            handler: { [weak self] _ in
                guard let self else { return }

                db.write { tx in
                    self.backupSettingsStore.setIsBackupDownloadQueueSuspended(true, tx: tx)
                }
            },
        ))
        actionSheet.addAction(.init(
            title: CommonStrings.learnMore,
            style: .default,
            handler: { _ in
                CurrentAppContext().open(
                    URL.Support.backups,
                    completion: nil,
                )
            },
        ))
        actionSheet.addAction(.init(
            title: CommonStrings.cancelButton,
            style: .cancel,
        ))
        CurrentAppContext().frontmostViewController()?.presentActionSheet(actionSheet)
    }

    // MARK: - Constants

    private enum Constants {
        static let spacing: CGFloat = 12
        static let iconSize: CGFloat = 24

        static var titleLabelFont: UIFont { .dynamicTypeSubheadlineClamped.bold() }
        static var subtitleLabelFont: UIFont { .dynamicTypeSubheadlineClamped.monospaced() }

        static var diskSpaceLabelFont: UIFont { .dynamicTypeSubheadlineClamped }

        static let detailsButtonText = OWSLocalizedString(
            "RESTORING_MEDIA_BANNER_DISK_SPACE_BUTTON",
            comment: "Button title shown on chat list banner for restoring media from a backup when paused because the device has insufficient disk space, to see a bottom sheet with more details about next steps.",
        )
        static var detailsButtonFont: UIFont { .dynamicTypeSubheadlineClamped.bold() }

        static let resumeButtonText = OWSLocalizedString(
            "RESTORING_MEDIA_BANNER_RESUME_WITHOUT_WIFI_BUTTON",
            comment: "Button title shown on chat list banner for restoring media from a backup when paused because the device needs WiFi to continue, to resume downloads without WiFi.",
        )
        static var resumeButtonFont: UIFont { .dynamicTypeSubheadlineClamped.bold() }
    }

    // MARK: ArcView

    private class ArcView: UIView {

        var percentComplete: Float = 0 {
            didSet {
                setNeedsDisplay()
            }
        }

        init() {
            super.init(frame: .zero)
            self.isOpaque = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Unimplemented")
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let lineWidth: CGFloat = 3
            let radius = min(rect.width, rect.height) / 2 - lineWidth / 2

            context.setStrokeColor(UIColor.Signal.secondaryLabel.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)

            context.addArc(
                center: center,
                radius: radius,
                startAngle: 0,
                endAngle: 2 * .pi,
                clockwise: false,
            )

            context.strokePath()

            let startAngle: CGFloat = -.pi / 2
            let endAngle = 2 * .pi * CGFloat(percentComplete)
            context.setStrokeColor(UIColor.Signal.ultramarine.cgColor)

            context.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle + startAngle,
                clockwise: false,
            )

            context.strokePath()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            setNeedsDisplay()
        }
    }
}

// MARK: -

#if DEBUG

private class BackupDownloadProgressPreviewViewController: UIViewController {
    private let state: BackupAttachmentDownloadProgressView.State

    init(state: BackupAttachmentDownloadProgressView.State) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let progressView = BackupAttachmentDownloadProgressView(
            forPreview: (),
            state: state,
        )
        view.addSubview(progressView)
        progressView.autoPinEdges(toSuperviewMarginsExcludingEdge: .bottom)
    }
}

@available(iOS 17, *)
#Preview("Restoring") {
    return BackupDownloadProgressPreviewViewController(state: .restoring(
        bytesDownloaded: 1_000_000_000,
        totalBytesToDownload: 2_400_000_000,
        percentageDownloaded: 1 / 2.4,
    ))
}

@available(iOS 17, *)
#Preview("Low Power") {
    return BackupDownloadProgressPreviewViewController(state: .paused(reason: .lowPowerMode))
}

#endif
