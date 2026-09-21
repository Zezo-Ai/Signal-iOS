//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

// MARK: - ContentSizedSheetViewController

/// A native sheet sized based on its content.
///
/// On iOS 15, default sheet detents are used.
@MainActor
public protocol ContentSizedSheetViewController: UIViewController {
    func customSheetHeight() -> CGFloat?

    func reloadSheetHeight()
}

extension ContentSizedSheetViewController {
    public func reloadSheetHeight() {
        sheetPresentationController?.reloadContentSizedHeight()
    }
}

// MARK: - SheetNavigationController

/// A navigation controller for `ContentSizedSheetViewController`s.
open class SheetNavigationController: UINavigationController {
    open var sheetBackgroundColor: UIColor { UIColor.Signal.groupedBackground }

    override public init(rootViewController: UIViewController) {
        // `init(rootViewController:)` calls `viewDidLoad` too
        // soon for the sheet to be properly initialized.
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        viewControllers = [rootViewController]
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open func viewDidLoad() {
        super.viewDidLoad()
        if #unavailable(iOS 26) {
            view.backgroundColor = sheetBackgroundColor
        }
        // Set the height before the presentation animation
        sheetPresentationController?.setUpContentSizedDetents()
    }

    override open func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The presentation jumps if you try to set the height here,
        // pre-iOS 26 jumps if you don't set it here 🤷‍♀️
        if #unavailable(iOS 26) {
            sheetPresentationController?.reloadContentSizedHeight(animated: false)
        }
    }

    /// Push with a fade to make the animations less jarring with a simultaneous sheet size change
    public func pushViewControllerWithFade(_ viewController: ContentSizedSheetViewController) {
        addFadeTransition()
        pushViewController(viewController, animated: false)
    }

    /// Pop with a fade to make the animations less jarring with a simultaneous sheet size change
    @discardableResult
    public func popViewControllerWithFade() -> UIViewController? {
        addFadeTransition()
        return popViewController(animated: false)
    }

    private func addFadeTransition() {
        let transition = CATransition()
        transition.duration = 0.3
        transition.type = .fade
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer.add(transition, forKey: nil)
    }
}

// MARK: - UISheetPresentationController + detents

extension UISheetPresentationController {
    /// Call this in a sheet's `viewDidLoad` install the detent
    /// (the height of which can be changed later).
    public func setUpContentSizedDetents() {
        guard #available(iOS 16, *) else {
            detents = [.medium(), .large()]
            return
        }
        guard !detents.contains(where: { $0.identifier == .contentHeight }) else { return }
        detents = [.custom(identifier: .contentHeight) { [weak self] context in
            guard let self else { return context.maximumDetentValue }
            if presentedViewController.view.bounds.isEmpty {
                // Layout now to get a non-zero initial height
                self.presentedViewController.view.layoutIfNeeded()
            }

            return min(
                self.contentSizedSheetContent?.customSheetHeight() ?? context.maximumDetentValue,
                context.maximumDetentValue,
            )
        }]
    }

    /// Call after setUpContentSizedDetents when the frontmost
    /// `ContentSizedSheetViewController`'s height changes.
    public func reloadContentSizedHeight(animated: Bool = true) {
        guard
            #available(iOS 16, *),
            detents.contains(where: { $0.identifier == .contentHeight })
        else { return }
        guard animated else {
            invalidateDetents()
            return
        }
        animateChanges {
            invalidateDetents()
        }
    }

    /// Frontmost `ContentSizedSheetViewController`
    private var contentSizedSheetContent: ContentSizedSheetViewController? {
        if let content = presentedViewController as? ContentSizedSheetViewController {
            return content
        }
        if let navigationController = presentedViewController as? UINavigationController {
            return navigationController.topViewController as? ContentSizedSheetViewController
        }
        return nil
    }
}

// MARK: -

extension UISheetPresentationController.Detent.Identifier {
    public static let contentHeight = Self("org.signal.contentHeight")
}
