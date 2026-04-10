//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

// A modal view that be used during blocking interactions (e.g. waiting on response from
// service or on the completion of a long-running local operation).
public class ModalActivityIndicatorViewController: OWSViewController {
    public enum Constants {
        public static let defaultPresentationDelay: TimeInterval = 0.05
    }

    public private(set) var wasCancelled: Bool = false

    private let canCancel: Bool
    private let isInvisible: Bool
    private var wasDimissed: Bool = false
    private var presentTimer: Timer?
    private let presentationDelay: TimeInterval
    private var asyncTask: Task<Void, Never>?

    public init(canCancel: Bool, presentationDelay: TimeInterval, isInvisible: Bool = false) {
        self.canCancel = canCancel
        self.presentationDelay = presentationDelay
        self.isInvisible = isInvisible
        super.init()
    }

    // MARK: -

    @MainActor
    public class func present(
        fromViewController: UIViewController,
        title: String? = nil,
        canCancel: Bool,
        presentationDelay: TimeInterval = Constants.defaultPresentationDelay,
        backgroundBlockQueueQos: DispatchQoS = .default,
        backgroundBlock: @escaping (ModalActivityIndicatorViewController) -> Void,
    ) {
        present(
            fromViewController: fromViewController,
            title: title,
            canCancel: canCancel,
            presentationDelay: presentationDelay,
            isInvisible: false,
            backgroundBlockQueueQos: backgroundBlockQueueQos,
            backgroundBlock: backgroundBlock,
        )
    }

    @MainActor
    public class func presentAsInvisible(
        fromViewController: UIViewController,
        backgroundBlock: @escaping (ModalActivityIndicatorViewController) -> Void,
    ) {
        present(
            fromViewController: fromViewController,
            title: nil,
            canCancel: false,
            presentationDelay: Constants.defaultPresentationDelay,
            isInvisible: true,
            backgroundBlockQueueQos: .default,
            backgroundBlock: backgroundBlock,
        )
    }

    @MainActor
    private class func present(
        fromViewController: UIViewController,
        title: String?,
        canCancel: Bool,
        presentationDelay: TimeInterval,
        isInvisible: Bool,
        backgroundBlockQueueQos: DispatchQoS,
        backgroundBlock: @escaping (ModalActivityIndicatorViewController) -> Void,
    ) {
        AssertIsOnMainThread()

        let vc = ModalActivityIndicatorViewController(
            canCancel: canCancel,
            presentationDelay: presentationDelay,
            isInvisible: isInvisible,
        )
        vc.title = title
        vc.present(
            from: fromViewController,
            asyncBlock: { viewController in
                DispatchQueue.global(qos: backgroundBlockQueueQos.qosClass).async {
                    backgroundBlock(viewController)
                }
            },
        )
    }

    // MARK: -

    /// Presents a `ModalActivityIndicatorViewController`, behind which the
    /// given async block runs. Callers are expected to dismiss the modal at the
    /// completion of the async block.
    ///
    /// Use this API if you need fine-grained control over the modal dismissal
    /// behavior, or if you want a cancellable modal.
    ///
    /// - SeeAlso ``presentAndPropagateResult(from:presentationDelay:wrappedAsyncBlock:)``
    @MainActor
    public class func present(
        fromViewController: UIViewController,
        title: String? = nil,
        canCancel: Bool = false,
        presentationDelay: TimeInterval = Constants.defaultPresentationDelay,
        isInvisible: Bool = false,
        asyncBlock: @escaping @MainActor (ModalActivityIndicatorViewController) async -> Void,
    ) {
        AssertIsOnMainThread()

        let vc = ModalActivityIndicatorViewController(
            canCancel: canCancel,
            presentationDelay: presentationDelay,
            isInvisible: isInvisible,
        )
        vc.title = title
        vc.present(
            from: fromViewController,
            asyncBlock: asyncBlock,
        )
    }

    /// Presents a `ModalActivityIndicatorViewController` for the duration of
    /// the given async block, automatically dismissing the modal when the block
    /// exits and propagating the block's result.
    ///
    /// Use this API if you want to simply show a modal during a non-cancellable
    /// async block.
    ///
    /// - SeeAlso ``present(fromViewController:canCancel:presentationDelay:isInvisible:asyncBlock:)``.
    @MainActor
    public class func presentAndPropagateResult<T, E>(
        from viewController: UIViewController,
        title: String? = nil,
        canCancel: Bool = false,
        presentationDelay: TimeInterval = Constants.defaultPresentationDelay,
        wrappedAsyncBlock: @escaping () async throws(E) -> T,
    ) async throws(E) -> T {
        let result: Result<T, E> = await withCheckedContinuation { continuation in
            present(
                fromViewController: viewController,
                title: title,
                canCancel: canCancel,
                presentationDelay: presentationDelay,
                asyncBlock: { modal in
                    let result = await Result(catching: wrappedAsyncBlock)
                    modal.dismiss {
                        continuation.resume(returning: result)
                    }
                },
            )
        }

        return try result.get()
    }

    @MainActor
    private func present(
        from viewController: UIViewController,
        asyncBlock: @escaping @MainActor (ModalActivityIndicatorViewController) async -> Void,
    ) {
        // Present this modal _over_ the current view contents.
        self.modalPresentationStyle = .overFullScreen
        viewController.present(self, animated: false) {
            self.asyncTask = Task { await asyncBlock(self) }
            if self.wasCancelled {
                self.asyncTask?.cancel()
            }
        }
    }

    // MARK: -

    public func dismiss(completion: (() -> Void)? = nil) {
        AssertIsOnMainThread()

        if !wasDimissed {
            // Only dismiss once.
            self.dismiss(animated: false, completion: completion)
            wasDimissed = true
        } else {
            // If already dismissed, wait a beat then call completion.
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// A helper for a common dismissal pattern.
    ///
    /// This can be invoked on any queue, and it'll switch to the main queue if
    /// needed. The completion block will be invoked on the main queue.
    ///
    /// - Parameter completionIfNotCanceled:
    ///     If the modal hasn't been canceled, dismiss it and then call this
    ///     block. Note: If the modal was canceled, the block isn't invoked.
    public func dismissIfNotCanceled(completionIfNotCanceled: @escaping () -> Void = {}) {
        DispatchQueue.main.async {
            if self.wasCancelled {
                return
            }
            self.dismiss(completion: completionIfNotCanceled)
        }
    }

    // MARK: -

    override public var title: String? {
        didSet {
            guard isViewLoaded else { return }
            updateUIOnTextChange()
        }
    }

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .dynamicTypeHeadline
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .Signal.label
        label.textAlignment = .natural
        label.numberOfLines = 5
        label.lineBreakMode = .byWordWrapping
        return label
    }()

    private lazy var textStack: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [])
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.directionalLayoutMargins = .init(top: 12, leading: 8, bottom: 0, trailing: 12)
        stackView.axis = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        return stackView
    }()

    private lazy var cancelButton: UIButton = {
        let button = UIButton(
            configuration: .borderedProminent(),
            primaryAction: UIAction { [weak self] _ in
                self?.cancelPressed()
            },
        )
        button.configuration?.title = CommonStrings.cancelButton
        button.configuration?.titleTextAttributesTransformer = .defaultFont(.dynamicTypeBodyClamped.medium())
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.configuration?.baseForegroundColor = .Signal.label
        button.configuration?.baseBackgroundColor = .Signal.secondaryFill
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(hMargin: 16, vMargin: 12)
        if #available(iOS 26, *) {
            button.configuration?.cornerStyle = .capsule
        } else {
            button.configuration?.cornerStyle = .fixed
            button.configuration?.background.cornerRadius = 14
        }

        return button
    }()

    private lazy var activityIndicator = CircularProgressView(frame: .zero)

    private lazy var contentStack: UIStackView = {
        activityIndicator.lineWidth = 3
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        let aiContainer = UIView.container()
        aiContainer.layoutMargins = .init(margin: 12)
        aiContainer.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.widthAnchor.constraint(equalToConstant: 40),
            activityIndicator.heightAnchor.constraint(equalTo: activityIndicator.widthAnchor),

            activityIndicator.topAnchor.constraint(equalTo: aiContainer.layoutMarginsGuide.topAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: aiContainer.layoutMarginsGuide.centerYAnchor),

            activityIndicator.leadingAnchor.constraint(greaterThanOrEqualTo: aiContainer.layoutMarginsGuide.leadingAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: aiContainer.layoutMarginsGuide.centerXAnchor),
        ])
        let stackView = UIStackView(arrangedSubviews: [textStack, aiContainer])
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 18
        return stackView
    }()

    private lazy var panelView: UIVisualEffectView = {
        if #available(iOS 26, *) {
            let glassEffect = UIGlassEffect(style: .regular)
            glassEffect.tintColor = UIColor.Signal.background.withAlphaComponent(2 / 3)
            let view = UIVisualEffectView(effect: glassEffect)
            view.clipsToBounds = true
            view.cornerConfiguration = .uniformCorners(radius: .fixed(canCancel ? 36 : 24))
            return view
        }

        let view = UIVisualEffectView(effect: UIBlurEffect(style: .prominent))
        view.clipsToBounds = true
        view.layer.cornerRadius = 28
        return view
    }()

    override public func viewDidLoad() {
        super.viewDidLoad()

        view.isOpaque = false
        view.tintColor = .Signal.label

        if isInvisible {
            view.backgroundColor = .clear
        } else {
            view.backgroundColor = .Signal.backdrop

            panelView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panelView)
            NSLayoutConstraint.activate([
                panelView.leadingAnchor.constraint(greaterThanOrEqualTo: contentLayoutGuide.leadingAnchor),
                panelView.centerXAnchor.constraint(equalTo: contentLayoutGuide.centerXAnchor),
                panelView.topAnchor.constraint(greaterThanOrEqualTo: contentLayoutGuide.topAnchor),
                panelView.centerYAnchor.constraint(equalTo: contentLayoutGuide.centerYAnchor),
                panelView.heightAnchor.constraint(lessThanOrEqualTo: panelView.widthAnchor, multiplier: 1),
            ])

            contentStack.translatesAutoresizingMaskIntoConstraints = false
            panelView.layoutMargins = .init(margin: 16)
            panelView.contentView.addSubview(contentStack)
            NSLayoutConstraint.activate([
                contentStack.topAnchor.constraint(equalTo: panelView.layoutMarginsGuide.topAnchor),
                contentStack.leadingAnchor.constraint(equalTo: panelView.layoutMarginsGuide.leadingAnchor),
                contentStack.trailingAnchor.constraint(equalTo: panelView.layoutMarginsGuide.trailingAnchor),
                contentStack.bottomAnchor.constraint(equalTo: panelView.layoutMarginsGuide.bottomAnchor),
            ])

            if canCancel {
                cancelButton.translatesAutoresizingMaskIntoConstraints = false
                cancelButton.addConstraint(cancelButton.widthAnchor.constraint(equalToConstant: 240))
                contentStack.addArrangedSubview(cancelButton)
            }

            updateUIOnTextChange()
        }

        // Hide the modal until the presentation animation completes.
        if presentationDelay > 0 {
            view.alpha = 0
        }
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        activityIndicator.startAnimating()

        // Hide the modal and wait for a second before revealing it,
        // to avoid "blipping" in the modal during short blocking operations.
        //
        // NOTE: It will still intercept user interactions while hidden, as it
        //       should.
        if presentationDelay > 0 {
            presentTimer?.invalidate()
            presentTimer = Timer.scheduledTimer(
                withTimeInterval: presentationDelay,
                repeats: false,
            ) { [weak self] _ in
                self?.presentTimerFired()
            }
        }
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        clearTimer()
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        activityIndicator.stopAnimating()

        clearTimer()
    }

    private func updateUIOnTextChange() {
        if let title = self.title?.nilIfEmpty {
            titleLabel.text = title
            if titleLabel.superview == nil {
                textStack.insertArrangedSubview(titleLabel, at: 0)
            }
            textStack.isHiddenInStackView = false
        } else {
            textStack.isHiddenInStackView = true
        }
    }

    // MARK: -

    private func clearTimer() {
        presentTimer?.invalidate()
        presentTimer = nil
    }

    private func presentTimerFired() {
        AssertIsOnMainThread()

        clearTimer()

        // Fade in the modal.
        UIView.animate(withDuration: 0.35) {
            self.view.alpha = 1
        }
    }

    @objc
    private func cancelPressed() {
        AssertIsOnMainThread()

        guard wasDimissed == false else { return }

        dismiss()
        wasCancelled = true
        asyncTask?.cancel()
    }
}

#if DEBUG

private class MAIVCPreviewViewController: UIViewController {

    private let canCancel: Bool

    init(title: String?, canCancel: Bool) {
        self.canCancel = canCancel
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { owsFail("") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let vc = ModalActivityIndicatorViewController(canCancel: canCancel, presentationDelay: 0)
        vc.title = title
        present(vc, animated: false)
        view.addSubview(vc.view)
        vc.didMove(toParent: self)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            vc.viewDidAppear(true)
        }
    }
}

@available(iOS 17, *)
#Preview("No Title, Can't Cancel") {
    MAIVCPreviewViewController(title: nil, canCancel: false)
}

@available(iOS 17, *)
#Preview("No Title, Can Cancel") {
    MAIVCPreviewViewController(title: nil, canCancel: true)
}

@available(iOS 17, *)
#Preview("Title, Can Cancel") {
    MAIVCPreviewViewController(title: "Preparing...", canCancel: true)
}

#endif
