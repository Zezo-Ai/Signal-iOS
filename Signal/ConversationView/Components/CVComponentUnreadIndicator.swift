//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

public class CVComponentUnreadIndicator: CVComponentBase, CVRootComponent {

    public var componentKey: CVComponentKey { .unreadIndicator }

    public var cellReuseIdentifier: CVCellReuseIdentifier {
        CVCellReuseIdentifier.unreadIndicator
    }

    public let isDedicatedCell = true

    override init(itemModel: CVItemModel) {
        super.init(itemModel: itemModel)
    }

    public func configureCellRootComponent(
        cellView: UIView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
        messageSwipeActionState: CVMessageSwipeActionState,
        componentView: CVComponentView,
    ) {
        Self.configureCellRootComponent(
            rootComponent: self,
            cellView: cellView,
            cellMeasurement: cellMeasurement,
            componentDelegate: componentDelegate,
            componentView: componentView,
        )
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewUnreadIndicator()
    }

    override public func wallpaperBlurView(componentView: CVComponentView) -> CVWallpaperBlurView? {
        guard let componentView = componentView as? CVComponentViewUnreadIndicator else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        return componentView.wallpaperBlurView
    }

    public func configureForRendering(
        componentView: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentView as? CVComponentViewUnreadIndicator else {
            owsFailDebug("Unexpected componentView.")
            return
        }

        let themeHasChanged = conversationStyle.isDarkThemeEnabled != componentView.isDarkThemeEnabled
        let hasWallpaper = conversationStyle.hasWallpaper
        let wallpaperModeHasChanged = hasWallpaper != componentView.hasWallpaper

        let isReusing = (
            componentView.rootView.superview != nil &&
                !themeHasChanged &&
                !wallpaperModeHasChanged,
        )

        if !isReusing {
            componentView.reset(resetReusableState: true)
        }

        componentView.isDarkThemeEnabled = conversationStyle.isDarkThemeEnabled
        componentView.hasWallpaper = hasWallpaper

        let outerStack = componentView.outerStack
        let innerStack = componentView.innerStack
        let strokeView = componentView.strokeView
        let titleLabel = componentView.titleLabel
        titleLabelConfig.applyForRendering(label: titleLabel)

        if isReusing {
            innerStack.configureForReuse(
                config: innerStackConfig,
                cellMeasurement: cellMeasurement,
                measurementKey: Self.measurementKey_innerStack,
            )
            outerStack.configureForReuse(
                config: outerStackConfig,
                cellMeasurement: cellMeasurement,
                measurementKey: Self.measurementKey_outerStack,
            )
        } else {
            outerStack.reset()
            titleLabel.removeFromSuperview()
            componentView.wallpaperBlurView?.removeFromSuperview()
            componentView.wallpaperBlurView = nil

            innerStack.reset()
            innerStack.configure(
                config: innerStackConfig,
                cellMeasurement: cellMeasurement,
                measurementKey: Self.measurementKey_innerStack,
                subviews: [titleLabel],
            )

            if hasWallpaper {
                let topStrokeColor = UIColor(rgbHex: 0x525252, alpha: isDarkThemeEnabled ? 0.32 : 0.24)
                let bottomStrokeColor = UIColor(white: 1, alpha: 0.12)
                strokeView.setStrokeColor(top: topStrokeColor, bottom: bottomStrokeColor)

                let wallpaperBlurView = componentView.ensureWallpaperBlurView()
                configureWallpaperBlurView(
                    wallpaperBlurView: wallpaperBlurView,
                    componentDelegate: componentDelegate,
                    hasPillRounding: true,
                    strokeConfig: ConversationStyle.bubbleStrokeConfiguration(isDarkThemeEnabled: isDarkThemeEnabled),
                )
                innerStack.addSubviewToFillSuperviewEdges(wallpaperBlurView)
            } else {
                strokeView.setStrokeColor(top: .ows_gray45, bottom: .clear)
            }

            outerStack.configure(
                config: outerStackConfig,
                cellMeasurement: cellMeasurement,
                measurementKey: Self.measurementKey_outerStack,
                subviews: [
                    strokeView,
                    innerStack,
                ],
            )
        }
    }

    private var titleLabelConfig: CVLabelConfig {
        CVLabelConfig.unstyledText(
            OWSLocalizedString(
                "MESSAGES_VIEW_UNREAD_INDICATOR",
                comment: "Indicator that separates read from unread messages.",
            ),
            font: UIFont.dynamicTypeFootnote.medium(),
            textColor: Theme.primaryTextColor,
            numberOfLines: 0,
            lineBreakMode: .byTruncatingTail,
            textAlignment: .center,
        )
    }

    private var outerStackConfig: CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .fill,
            spacing: 12,
            layoutMargins: UIEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0),
        )
    }

    private var innerStackConfig: CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .center,
            spacing: 0,
            layoutMargins: UIEdgeInsets(hMargin: 12, vMargin: 3),
        )
    }

    private static let measurementKey_outerStack = "CVComponentUnreadIndicator.measurementKey_outerStack"
    private static let measurementKey_innerStack = "CVComponentUnreadIndicator.measurementKey_innerStack"

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let availableWidth = max(
            0,
            maxWidth -
                (
                    innerStackConfig.layoutMargins.totalWidth +
                        outerStackConfig.layoutMargins.totalWidth
                ),
        )
        let labelSize = CVText.measureLabel(config: titleLabelConfig, maxWidth: availableWidth)
        let strokeSize = CGSize(width: 0, height: 1)

        let labelInfo = labelSize.asManualSubviewInfo
        let innerStackMeasurement = ManualStackView.measure(
            config: innerStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_innerStack,
            subviewInfos: [labelInfo],
        )

        let strokeInfo = strokeSize.asManualSubviewInfo(hasFixedHeight: true)
        let innerStackInfo = innerStackMeasurement.measuredSize.asManualSubviewInfo(hasFixedWidth: true)
        let vStackSubviewInfos = [
            strokeInfo,
            innerStackInfo,
        ]
        let vStackMeasurement = ManualStackView.measure(
            config: outerStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_outerStack,
            subviewInfos: vStackSubviewInfos,
            maxWidth: maxWidth,
        )
        return vStackMeasurement.measuredSize
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewUnreadIndicator: NSObject, CVComponentView {

        fileprivate let outerStack = ManualStackView(name: "unreadIndicator.outerStack")
        fileprivate let innerStack = ManualStackView(name: "unreadIndicator.innerStack")

        fileprivate let titleLabel = CVLabel()

        fileprivate var wallpaperBlurView: CVWallpaperBlurView?
        fileprivate func ensureWallpaperBlurView() -> CVWallpaperBlurView {
            if let wallpaperBlurView = self.wallpaperBlurView {
                return wallpaperBlurView
            }
            let wallpaperBlurView = CVWallpaperBlurView()
            self.wallpaperBlurView = wallpaperBlurView
            return wallpaperBlurView
        }

        fileprivate var hasWallpaper = false
        fileprivate var isDarkThemeEnabled = false

        fileprivate let strokeView = DoubleStrokeView()

        public var isDedicatedCellView = false

        public var rootView: UIView {
            outerStack
        }

        // MARK: -

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            reset(resetReusableState: false)
        }

        public func reset(resetReusableState: Bool) {
            owsAssertDebug(isDedicatedCellView)

            titleLabel.text = nil

            if resetReusableState {
                outerStack.reset()
                innerStack.reset()

                wallpaperBlurView?.removeFromSuperview()

                hasWallpaper = false
                isDarkThemeEnabled = false
            }
        }
    }

    fileprivate class DoubleStrokeView: ManualLayoutView {

        private let topStrokeView = UIView()
        private let bottomStrokeView = UIView()

        init() {
            super.init(name: "DoubleStrokeView")

            clipsToBounds = true

            addSubview(topStrokeView)
            addSubview(bottomStrokeView)

            addDefaultLayoutBlock()
        }

        private func addDefaultLayoutBlock() {
            addLayoutBlock { [weak self] _ in
                guard let self else { return }

                let strokeViewSize = CGSize(width: self.bounds.width, height: CGFloat.hairlineWidth)

                self.topStrokeView.frame = CGRect(
                    origin: CGPoint(x: self.bounds.minX, y: self.bounds.minY),
                    size: strokeViewSize,
                )
                self.bottomStrokeView.frame = CGRect(
                    origin: CGPoint(x: self.bounds.minX, y: self.topStrokeView.frame.maxY),
                    size: strokeViewSize,
                )
            }
        }

        func setStrokeColor(top: UIColor, bottom: UIColor) {
            topStrokeView.backgroundColor = top
            bottomStrokeView.backgroundColor = bottom
        }
    }
}
