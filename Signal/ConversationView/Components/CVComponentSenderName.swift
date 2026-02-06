//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

public class CVComponentSenderName: CVComponentBase, CVComponent {

    public var componentKey: CVComponentKey { .senderName }

    private let state: CVComponentState.SenderName
    private var senderName: NSAttributedString {
        // The breaking space ensures the member label can line-break from the sender name.
        // The non-breaking spaces make sure the label doesn't get cut off if it starts a new line.
        let padding = " " + String(repeating: SignalSymbol.LeadingCharacter.nonBreakingSpace.rawValue, count: 2)
        if let labelString = state.memberLabel {
            if CurrentAppContext().isRTL {
                return NSAttributedString(string: labelString + padding) + state.senderName
            } else {
                return state.senderName + padding + labelString
            }
        } else {
            return state.senderName
        }
    }

    private var senderNameColor: UIColor { state.senderNameColor }
    private var memberLabel: String? { state.memberLabel }

    init(itemModel: CVItemModel, senderNameState: CVComponentState.SenderName) {
        self.state = senderNameState

        super.init(itemModel: itemModel)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewSenderName()
    }

    private var bodyTextColor: UIColor {
        guard let message = interaction as? TSMessage else {
            return .black
        }
        return conversationStyle.bubbleTextColor(message: message)
    }

    public func configureForRendering(
        componentView componentViewParam: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentViewParam as? CVComponentViewSenderName else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let outerStack = componentView.outerStack
        let innerStack = componentView.innerStack

        outerStack.reset()
        innerStack.reset()

        if isBorderlessWithWallpaper {
            owsAssertDebug(isIncoming)

            let backgroundView = CVColorOrGradientView()
            backgroundView.configure(
                value: conversationStyle.bubbleChatColorIncoming,
                referenceView: componentDelegate.view,
                hasPillRounding: true,
            )
            innerStack.addSubviewToFillSuperviewEdges(backgroundView)
        }

        if let memberLabel = state.memberLabel {
            // Finds the first or last occurance of the member label.
            // Since member label is appended to the end in LTR and beginning in RTL, this
            // will work even if member label is a substring of sender name or equal to sender name.
            var options: NSString.CompareOptions = []
            if !CurrentAppContext().isRTL {
                options.insert(.backwards)
            }
            componentView.label = CVCapsuleLabel(
                attributedText: senderName,
                textColor: senderNameColor,
                font: UIFont.dynamicTypeFootnote.semibold(),
                highlightRange: (senderName.string as NSString).range(of: memberLabel, options: options),
                highlightFont: .dynamicTypeFootnote,
                axLabelPrefix: nil, // handled separately in CVItemViewState
                isQuotedReply: false,
            )
        } else {
            labelConfig.applyForRendering(label: componentView.label)
        }

        var subviews: [UIView] = []
        subviews.append(componentView.label)

        innerStack.configure(
            config: innerStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_innerStack,
            subviews: subviews,
        )
        outerStack.configure(
            config: outerStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_outerStack,
            subviews: [innerStack],
        )
    }

    private var isBorderlessWithWallpaper: Bool {
        return isBorderless && conversationStyle.hasWallpaper
    }

    private var labelConfig: CVLabelConfig {
        let font = UIFont.dynamicTypeFootnote.semibold()
        return CVLabelConfig(
            text: .attributedText(senderName),
            displayConfig: .forUnstyledText(font: font, textColor: senderNameColor),
            font: font,
            textColor: senderNameColor,
            numberOfLines: 0,
            lineBreakMode: .byWordWrapping,
        )
    }

    private var outerStackConfig: CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .leading,
            spacing: 0,
            layoutMargins: .zero,
        )
    }

    private var innerStackConfig: CVStackViewConfig {
        let layoutMargins: UIEdgeInsets = (
            isBorderlessWithWallpaper
                ? UIEdgeInsets(hMargin: 12, vMargin: 3)
                : .zero,
        )
        return CVStackViewConfig(
            axis: .horizontal,
            alignment: .center,
            spacing: 4,
            layoutMargins: layoutMargins,
        )
    }

    private static let measurementKey_outerStack = "CVComponentSenderName.measurementKey_outerStack"
    private static let measurementKey_innerStack = "CVComponentSenderName.measurementKey_innerStack"

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let maxWidth = maxWidth - (
            outerStackConfig.layoutMargins.totalWidth +
                innerStackConfig.layoutMargins.totalWidth
        )

        var subviewInfos: [ManualStackSubviewInfo] = []
        let labelSize: CGSize
        if state.memberLabel != nil {
            labelSize = CVCapsuleLabel.measureLabel(
                config: labelConfig,
                maxWidth: maxWidth,
            )
        } else {
            labelSize = CVText.measureLabel(config: labelConfig, maxWidth: maxWidth)
        }
        let labelInfo = labelSize.asManualSubviewInfo
        subviewInfos.insert(labelInfo, at: 0)

        let innerStackMeasurement = ManualStackView.measure(
            config: innerStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_innerStack,
            subviewInfos: subviewInfos,
        )
        let innerStackInfo = innerStackMeasurement.measuredSize.asManualSubviewInfo
        let outerStackMeasurement = ManualStackView.measure(
            config: outerStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_outerStack,
            subviewInfos: [innerStackInfo],
            maxWidth: maxWidth,
        )
        return outerStackMeasurement.measuredSize
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewSenderName: NSObject, CVComponentView {

        fileprivate var label = UILabel()

        fileprivate let outerStack = ManualStackView(name: "CVComponentViewSenderName.outerStack")
        fileprivate let innerStack = ManualStackView(name: "CVComponentViewSenderName.innerStack")

        public var isDedicatedCellView = false

        public var rootView: UIView {
            outerStack
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            outerStack.reset()
            innerStack.reset()

            label.text = nil
        }

    }
}
