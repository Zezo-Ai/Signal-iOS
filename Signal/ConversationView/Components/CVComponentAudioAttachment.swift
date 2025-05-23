//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
public import SignalUI

public class CVComponentAudioAttachment: CVComponentBase, CVComponent {

    public var componentKey: CVComponentKey { .audioAttachment }

    private let audioAttachment: AudioAttachment
    private let nextAudioAttachment: AudioAttachment?
    private var attachment: Attachment { audioAttachment.attachment }
    private var attachmentStream: AttachmentStream? { audioAttachment.attachmentStream?.attachmentStream }
    private let footerOverlay: CVComponent?

    init(itemModel: CVItemModel, audioAttachment: AudioAttachment, nextAudioAttachment: AudioAttachment?, footerOverlay: CVComponent?) {
        self.audioAttachment = audioAttachment
        self.nextAudioAttachment = nextAudioAttachment
        self.footerOverlay = footerOverlay

        super.init(itemModel: itemModel)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // TODO: This type isn't well-equipped to implement this logic.
            DependenciesBridge.shared.databaseChangeObserver.appendDatabaseChangeDelegate(self)
            self.checkIfMessageStillExists()
        }
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewAudioAttachment()
    }

    public func configureForRendering(componentView componentViewParam: CVComponentView,
                                      cellMeasurement: CVCellMeasurement,
                                      componentDelegate: CVComponentDelegate) {
        guard let componentView = componentViewParam as? CVComponentViewAudioAttachment else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let stackView = componentView.stackView
        let conversationStyle = self.conversationStyle

        if let footerOverlay = self.footerOverlay {
            let footerView: CVComponentView
            if let footerOverlayView = componentView.footerOverlayView {
                footerView = footerOverlayView
            } else {
                let footerOverlayView = CVComponentFooter.CVComponentViewFooter()
                componentView.footerOverlayView = footerOverlayView
                footerView = footerOverlayView
            }
            footerOverlay.configureForRendering(componentView: footerView,
                                                cellMeasurement: cellMeasurement,
                                                componentDelegate: componentDelegate)
            let footerRootView = footerView.rootView

            let footerSize = cellMeasurement.size(key: Self.measurementKey_footerSize) ?? .zero
            stackView.addSubview(footerRootView) { view in
                var footerFrame = view.bounds
                footerFrame.height = min(view.bounds.height, footerSize.height)
                footerFrame.y = view.bounds.height - footerSize.height
                footerRootView.frame = footerFrame
            }
        }

        owsAssertDebug(MimeTypeUtil.isSupportedAudioMimeType(attachment.mimeType))
        let presentation = AudioMessagePresenter(
            isIncoming: isIncoming,
            audioAttachment: audioAttachment,
            threadUniqueId: itemModel.thread.uniqueId,
            playbackRate: AudioPlaybackRate(rawValue: itemModel.itemViewState.audioPlaybackRate))
        let audioMessageView = AudioMessageView(
            presentation: presentation,
            audioMessageViewDelegate: componentDelegate,
            mediaCache: mediaCache
        )
        if let incomingMessage = interaction as? TSIncomingMessage {
            audioMessageView.setViewed(incomingMessage.wasViewed, animated: false)
        } else if let outgoingMessage = interaction as? TSOutgoingMessage {
            audioMessageView.setViewed(!outgoingMessage.viewedRecipientAddresses().isEmpty, animated: false)
        }
        audioMessageView.configureForRendering(
            cellMeasurement: cellMeasurement,
            conversationStyle: conversationStyle
        )
        componentView.audioMessageView = audioMessageView
        stackView.configure(config: stackViewConfig,
                            cellMeasurement: cellMeasurement,
                            measurementKey: Self.measurementKey_stackView,
                            subviews: [ audioMessageView ])

        // Listen for when our audio attachment finishes playing, so we can
        // start playing the next attachment.
        AppEnvironment.shared.cvAudioPlayerRef.addListener(self)
    }

    private var stackViewConfig: CVStackViewConfig {
        CVStackViewConfig(axis: .vertical,
                          alignment: .fill,
                          spacing: 0,
                          layoutMargins: .zero)
    }

    private static let measurementKey_stackView = "CVComponentAudioAttachment.measurementKey_stackView"
    private static let measurementKey_footerSize = "CVComponentAudioAttachment.measurementKey_footerSize"

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let maxWidth = min(maxWidth, conversationStyle.maxAudioMessageWidth)

        if let footerOverlay = self.footerOverlay {
            let maxFooterWidth = max(0, maxWidth - conversationStyle.textInsets.totalWidth)
            let footerSize = footerOverlay.measure(maxWidth: maxFooterWidth,
                                                   measurementBuilder: measurementBuilder)
            measurementBuilder.setSize(key: Self.measurementKey_footerSize, size: footerSize)
        }

        let presentation = AudioMessagePresenter(
            isIncoming: false,
            audioAttachment: audioAttachment,
            threadUniqueId: itemModel.thread.uniqueId,
            playbackRate: AudioPlaybackRate(rawValue: itemModel.itemViewState.audioPlaybackRate))
        let audioSize = AudioMessageView.measure(
            maxWidth: maxWidth,
            measurementBuilder: measurementBuilder,
            presentation: presentation).ceil
        let audioInfo = audioSize.asManualSubviewInfo
        let stackMeasurement = ManualStackView.measure(config: stackViewConfig,
                                                       measurementBuilder: measurementBuilder,
                                                       measurementKey: Self.measurementKey_stackView,
                                                       subviewInfos: [ audioInfo ],
                                                       maxWidth: maxWidth)
        var measuredSize = stackMeasurement.measuredSize
        measuredSize.width = maxWidth
        return measuredSize
    }

    /// Checks if the message still exists and stops playback if it does not.
    private func checkIfMessageStillExists() {
        guard AppEnvironment.shared.cvAudioPlayerRef.audioPlaybackState(forAttachmentId: attachment.id) == .playing else {
            return
        }

        let messageWasDeleted = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TSInteraction.anyFetch(uniqueId: interaction.uniqueId, transaction: tx) == nil
        }
        guard messageWasDeleted else {
            return
        }

        AppEnvironment.shared.cvAudioPlayerRef.stopAll()
    }

    // MARK: - Events

    public override func handleTap(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem
    ) -> Bool {
        if
            let audioMessageView = (componentView as? CVComponentViewAudioAttachment)?.audioMessageView,
            audioMessageView.handleTap(sender: sender, itemModel: renderItem.itemModel)
        {
            return true
        }

        if audioAttachment.isDownloaded {
            AppEnvironment.shared.cvAudioPlayerRef.setPlaybackRate(
                renderItem.itemViewState.audioPlaybackRate,
                forThreadUniqueId: renderItem.itemModel.thread.uniqueId
            )
            AppEnvironment.shared.cvAudioPlayerRef.togglePlayState(forAudioAttachment: audioAttachment)

            // We mark audio attachments "viewed" when they're played.
            let timestamp = Date().ows_millisecondsSince1970
            let attachmentId = audioAttachment.attachment.id
            Task {
                try await DependenciesBridge.shared.db.awaitableWrite { tx in
                    guard let attachment = DependenciesBridge.shared.attachmentStore.fetch(id: attachmentId, tx: tx) else {
                        return
                    }
                    try DependenciesBridge.shared.attachmentStore.markViewedFullscreen(
                        attachment: attachment,
                        timestamp: timestamp,
                        tx: tx
                    )
                }
            }

            return true

        } else if audioAttachment.isDownloading, let pointerId = audioAttachment.attachmentPointer?.attachment.id {
            Logger.debug("Cancelling in-progress download because of user action: \(interaction.uniqueId):\(pointerId)")
            SSKEnvironment.shared.databaseStorageRef.write { tx in
                DependenciesBridge.shared.attachmentDownloadManager.cancelDownload(
                    for: pointerId,
                    tx: tx
                )
            }
            return true

        } else if let message = interaction as? TSMessage {
            Logger.debug("Retrying download for message: \(message.uniqueId)")
            componentDelegate.didTapFailedOrPendingDownloads(message)
            return true

        } else {
            owsFailDebug("Unexpected message type")
            return false
        }
    }

    // MARK: - Scrub Audio With Pan

    public override func findPanHandler(sender: UIPanGestureRecognizer,
                                        componentDelegate: CVComponentDelegate,
                                        componentView: CVComponentView,
                                        renderItem: CVRenderItem,
                                        messageSwipeActionState: CVMessageSwipeActionState) -> CVPanHandler? {
        AssertIsOnMainThread()

        guard let componentView = componentView as? CVComponentViewAudioAttachment else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
        guard componentDelegate.shouldAllowReplyForItem(itemViewModel) else {
            return nil
        }
        guard nil != attachmentStream else {
            return nil
        }
        guard let audioMessageView = componentView.audioMessageView else {
            owsFailDebug("Missing audioMessageView.")
            return nil
        }
        let location = sender.location(in: audioMessageView)
        guard audioMessageView.isPointInScrubbableRegion(location) else {
            return nil
        }

        return CVPanHandler(delegate: componentDelegate,
                            panType: .scrubAudio,
                            renderItem: renderItem)
    }

    public override func startPanGesture(sender: UIPanGestureRecognizer,
                                         panHandler: CVPanHandler,
                                         componentDelegate: CVComponentDelegate,
                                         componentView: CVComponentView,
                                         renderItem: CVRenderItem,
                                         messageSwipeActionState: CVMessageSwipeActionState) {
        AssertIsOnMainThread()
    }

    public override func handlePanGesture(sender: UIPanGestureRecognizer,
                                          panHandler: CVPanHandler,
                                          componentDelegate: CVComponentDelegate,
                                          componentView: CVComponentView,
                                          renderItem: CVRenderItem,
                                          messageSwipeActionState: CVMessageSwipeActionState) {
        AssertIsOnMainThread()

        guard let componentView = componentView as? CVComponentViewAudioAttachment else {
            owsFailDebug("Unexpected componentView.")
            return
        }
        guard let audioMessageView = componentView.audioMessageView else {
            owsFailDebug("Missing audioMessageView.")
            return
        }
        let location = sender.location(in: audioMessageView)
        guard let attachmentStream = attachmentStream else {
            return
        }
        switch sender.state {
        case .changed:
            let progress = audioMessageView.progressForLocation(location)
            audioMessageView.setOverrideProgress(progress, animated: false)
        case .ended:
            // Only update the actual playback position when the user finishes scrubbing,
            // we still call `scrubToLocation` above in order to update the slider.
            audioMessageView.clearOverrideProgress(animated: false)
            let scrubbedTime = audioMessageView.scrubToLocation(location)
            AppEnvironment.shared.cvAudioPlayerRef.setPlaybackProgress(progress: scrubbedTime, forAttachmentStream: attachmentStream)
        case .possible, .began, .failed, .cancelled:
            audioMessageView.clearOverrideProgress(animated: false)
        @unknown default:
            owsFailDebug("Invalid state.")
            audioMessageView.clearOverrideProgress(animated: false)
        }
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewAudioAttachment: NSObject, CVComponentView {

        fileprivate let stackView = ManualStackView(name: "CVComponentViewAudioAttachment.stackView")

        fileprivate var audioMessageView: AudioMessageView?

        fileprivate var footerOverlayView: CVComponentView?

        public var isDedicatedCellView = false

        public var rootView: UIView {
            stackView
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            stackView.reset()

            audioMessageView?.removeFromSuperview()
            audioMessageView = nil

            footerOverlayView?.reset()
            footerOverlayView = nil
        }
    }
}

// MARK: - CVAudioPlayerListener

extension CVComponentAudioAttachment: CVAudioPlayerListener {
    func audioPlayerStateDidChange(attachmentId: Attachment.IDType) {}

    func audioPlayerDidFinish(attachmentId: Attachment.IDType) {
        guard attachmentId == audioAttachment.attachment.id else { return }
        AppEnvironment.shared.cvAudioPlayerRef.autoplayNextAudioAttachmentIfNeeded(nextAudioAttachment)
    }

    func audioPlayerDidMarkViewed(attachmentId: Attachment.IDType) {}
}

// MARK: - DatabaseChangeDelegate

extension CVComponentAudioAttachment: DatabaseChangeDelegate {
    public func databaseChangesDidUpdate(databaseChanges: SignalServiceKit.DatabaseChanges) {
        guard databaseChanges.didUpdate(interaction: self.interaction) else {
            return
        }

        checkIfMessageStillExists()
    }

    public func databaseChangesDidUpdateExternally() {
        checkIfMessageStillExists()
    }

    public func databaseChangesDidReset() {
        checkIfMessageStillExists()
    }
}

// MARK: -

extension CVComponentAudioAttachment: CVAccessibilityComponent {
    public var accessibilityDescription: String {
        if audioAttachment.isVoiceMessage {
            if audioAttachment.durationSeconds > 0 && audioAttachment.durationSeconds < 60 {
                let format = OWSLocalizedString(
                    "ACCESSIBILITY_LABEL_SHORT_VOICE_MEMO_%d",
                    tableName: "PluralAware",
                    comment: "Accessibility label for a short (under 60 seconds) voice memo. Embeds: {{ the duration of the voice message in seconds }}."
                )
                return String.localizedStringWithFormat(format, Int(audioAttachment.durationSeconds))
            } else if audioAttachment.durationSeconds >= 60 {
                let minutes = (audioAttachment.durationSeconds / 60).rounded(.down)
                let seconds = audioAttachment.durationSeconds.truncatingRemainder(dividingBy: 60)
                let format = OWSLocalizedString(
                    "ACCESSIBILITY_LABEL_LONG_VOICE_MEMO_%d_%d",
                    tableName: "PluralAware",
                    comment: "Accessibility label for a long (60+ seconds) voice memo. Embeds: {{ %1$@ the minutes component of the duration, %2$@ the seconds component of the duration }}."
                )
                return String.localizedStringWithFormat(format, Int(minutes), Int(seconds))
            } else {
                return OWSLocalizedString("ACCESSIBILITY_LABEL_VOICE_MEMO",
                                         comment: "Accessibility label for a voice memo.")
            }
        } else {
            // TODO: We could include information about the attachment format.
            return OWSLocalizedString("ACCESSIBILITY_LABEL_AUDIO",
                                     comment: "Accessibility label for audio.")
        }
    }
}
