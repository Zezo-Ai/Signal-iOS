//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

private import PureLayout
private import SignalServiceKit
import UIKit

final class ChatListContainerView: UIView {
    let tableView: CLVTableView
    private unowned let searchBar: UISearchBar
    private var adjustedContentOffset: CGPoint = .zero
    private var needsFilterControlSizeChange = true
    private var sizeForControllerTransition: CGSize?
    private var smallestSafeArea = CGRect.infinite
    private var observation: NSKeyValueObservation?
    private var transitionAnimator: UIViewPropertyAnimator?
    private var _filterControl: ChatListFilterControl?

    private var isTransitioning: Bool {
        transitionAnimator != nil
    }

    var filterControl: ChatListFilterControl? {
        _filterControl
    }

    init(tableView: CLVTableView, searchBar: UISearchBar) {
        self.searchBar = searchBar
        self.tableView = tableView
        super.init(frame: .zero)

        addSubview(tableView)
        tableView.autoPinEdgesToSuperviewEdges()

        if FeatureFlags.chatListFilter {
            let filterControl = ChatListFilterControl(container: self, scrollView: tableView)
            _filterControl = filterControl
            insertSubview(filterControl, aboveSubview: tableView)

            observation = tableView.observe(\.contentOffset) { [weak self] _, _ in
                guard let self else { return }
                scrollPositionDidChange()
                updateContentHeight()
                filterControl.setAdjustedContentOffset(adjustedContentOffset)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            updateKnownSafeArea()
        } else {
            smallestSafeArea = .infinite
        }
    }

    func willTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        sizeForControllerTransition = size
        smallestSafeArea = .infinite
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()

        updateKnownSafeArea()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if filterControl != nil, traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            // The filter control needs to match the size of the search bar, which
            // changes depending on dynamic type. Set a flag so that we can
            // calculate the new search bar size in `layoutSubviews()`.
            needsFilterControlSizeChange = true
            smallestSafeArea = .infinite
            updateKnownSafeArea()
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        defer {
            needsFilterControlSizeChange = false

            if let sizeForControllerTransition, bounds.size == sizeForControllerTransition {
                self.sizeForControllerTransition = nil
            }
        }

        if let filterControl, needsFilterControlSizeChange {
            UIView.performWithoutAnimation {
                let searchBarHeight = searchBar.systemLayoutSizeFitting(UIView.layoutFittingExpandedSize).height
                filterControl.preferredContentHeight = searchBarHeight
            }
        }
    }

    // FIXME: unify this method with `ChatListFilterControl.State.isAnimatingTransition`
    func animateTransition(withDuration duration: CGFloat, animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
        if let transitionAnimator {
            // If we're already transitioning, just add the new animation to
            // the in-progress transition.

            transitionAnimator.addAnimations {
                animations()
            }

            if let completion {
                transitionAnimator.addCompletion { _ in
                    completion()
                }
            }
        } else {
            let transitionAnimator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut)
            self.transitionAnimator = transitionAnimator

            transitionAnimator.addAnimations {
                animations()
            }

            transitionAnimator.addCompletion { _ in
                self.transitionAnimator = nil
                completion?()
            }

            transitionAnimator.startAnimation()
        }
    }

    private func scrollPositionDidChange() {
        var contentOffset = tableView.contentOffset
        contentOffset.y += tableView.adjustedContentInset.top
        adjustedContentOffset = contentOffset
    }

    private func updateContentHeight() {
        guard !isTransitioning, let filterControl else { return }

        let height = if filterControl.state >= .willStartFiltering {
            filterControl.preferredContentHeight
        } else {
            max(0, min(filterControl.preferredContentHeight, tableView.contentInset.top - adjustedContentOffset.y))
        }

        UIView.performWithoutAnimation {
            filterControl.frame = CGRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: height)
        }
    }

    // A swipe threshold that feels good and is portable across many device
    // sizes is about 25% of the scrollable area.
    //
    // In order to make the swipe gesture threshold relative to the visible
    // scrollable area, we need to keep track of whenever the safe area gets
    // smaller (which happens as the content insets are automatically adjusted
    // to reveal the search bar), then recompute the threshold.
    private func updateKnownSafeArea() {
        guard let filterControl else { return }

        let fullFrame = if let size = sizeForControllerTransition {
            CGRect(origin: bounds.origin, size: size)
        } else {
            bounds
        }
        let layoutFrame = fullFrame.inset(by: safeAreaInsets)
        smallestSafeArea = smallestSafeArea.intersection(layoutFrame)

        filterControl.swipeGestureThreshold = smallestSafeArea.height * 0.25
    }
}