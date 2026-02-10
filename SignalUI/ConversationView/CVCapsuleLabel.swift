//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/**
 * Given an attributed string and a highlightRange, draws a colored capsule behind the characters in highlightRange.
 * The color of the capsule is determined by the textColor with opacity decreased.
 * highlightFont allows for the capsule text to be a different font (e.g. bold or not bold) from the rest of the attributed text.
 */
public class CVCapsuleLabel: UILabel {
    public let highlightRange: NSRange
    public let highlightFont: UIFont
    public let axLabelPrefix: String?
    public let isQuotedReply: Bool
    public let onTap: (() -> Void)?

    // *CapsuleInset is how far beyond the text the capsule expands.
    // *Offset is how shifted BOTH capsule & text are from the edge of the view.
    private static let horizontalCapsuleInset: CGFloat = 6
    private static let verticalCapsuleInset: CGFloat = 1
    private static let verticalOffset: CGFloat = 3
    private static let horizontalOffset: CGFloat = 6

    public init(
        attributedText: NSAttributedString,
        textColor: UIColor,
        font: UIFont?,
        highlightRange: NSRange,
        highlightFont: UIFont,
        axLabelPrefix: String?,
        isQuotedReply: Bool,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        numberOfLines: Int = 0,
        onTap: (() -> Void)?,
    ) {
        self.highlightRange = highlightRange
        self.highlightFont = highlightFont
        self.axLabelPrefix = axLabelPrefix
        self.isQuotedReply = isQuotedReply
        self.onTap = onTap

        super.init(frame: .zero)

        self.font = font
        self.attributedText = attributedText
        self.textColor = textColor
        self.lineBreakMode = lineBreakMode
        self.numberOfLines = numberOfLines

        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapMemberLabel)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var capsuleColor: UIColor {
        if Theme.isDarkThemeEnabled {
            if isQuotedReply {
                return UIColor.white.withAlphaComponent(0.20)
            }
            return textColor.withAlphaComponent(0.25)
        }
        if isQuotedReply {
            return UIColor.white.withAlphaComponent(0.36)
        }
        return textColor.withAlphaComponent(0.1)
    }

    @objc
    func didTapMemberLabel() {
        onTap?()
    }

    override public func drawText(in rect: CGRect) {
        guard let text = self.text else {
            super.drawText(in: rect)
            return
        }

        let attributedString = NSMutableAttributedString(string: text)
        attributedString.addAttribute(.font, value: self.font!, range: text.entireRange)
        attributedString.addAttribute(.foregroundColor, value: self.textColor!, range: text.entireRange)

        // The highlighted text may have different font than the sender name
        attributedString.addAttribute(.font, value: highlightFont, range: highlightRange)

        let textStorage = NSTextStorage(attributedString: attributedString)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: rect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = self.numberOfLines
        textContainer.lineBreakMode = self.lineBreakMode

        layoutManager.addTextContainer(textContainer)

        textStorage.addLayoutManager(layoutManager)

        // We only need to offset the capsule & text horizontally if the edge of the view
        // might cut it off, (location starts at 0).
        var horizontalOffset: CGFloat = 0
        let needsHorizontalOffset = highlightRange.location == 0
        if needsHorizontalOffset {
            horizontalOffset = CurrentAppContext().isRTL ? -Self.horizontalOffset : Self.horizontalOffset
        }

        let highlightGlyphRange = layoutManager.glyphRange(forCharacterRange: highlightRange, actualCharacterRange: nil)

        let highlightColor = capsuleColor
        layoutManager.enumerateEnclosingRects(forGlyphRange: highlightGlyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
            let vCapsuleOffset = -Self.verticalCapsuleInset + Self.verticalOffset
            let roundedRect = rect.offsetBy(
                dx: horizontalOffset,
                dy: vCapsuleOffset,
            ).insetBy(
                dx: -Self.horizontalCapsuleInset,
                dy: -Self.verticalCapsuleInset,
            )
            let path = UIBezierPath(roundedRect: roundedRect, cornerRadius: roundedRect.height / 2)
            highlightColor.setFill()
            path.fill()
        }

        let textOrigin = CGPoint(x: horizontalOffset, y: Self.verticalOffset)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: textOrigin)
    }

    // TODO: measureLabel is used in the CVC for message bubbles and quote replies.
    // its needed before the member label is initialized due to how CVComponents work.
    // ideally this would be refactored to not be a class func, so we could
    // share logic between this and highlightLabelSize().
    public class func measureLabel(config: CVLabelConfig, maxWidth: CGFloat) -> CGSize {
        let capsuleHPadding = horizontalCapsuleInset * 2
        let capsuleVPadding = verticalCapsuleInset * 2
        let memberLabelSize = CVText.measureLabel(config: config, maxWidth: maxWidth - capsuleHPadding)
        return CGSize(
            width: memberLabelSize.width + capsuleHPadding,
            height: memberLabelSize.height + capsuleVPadding,
        )
    }

    override public var intrinsicContentSize: CGSize {
        return highlightLabelSize()
    }

    func highlightLabelSize() -> CGSize {
        guard let text = self.text else { return .zero }
        let attributes: [NSAttributedString.Key: Any] = [.font: highlightFont]
        let size = (text as NSString).size(withAttributes: attributes)

        // The size must take into account both the extended size of the capsule, but
        // also any amount that we've shifted the capsule/text horizontally or vertically.
        return CGSize(
            width: size.width + Self.horizontalOffset + Self.horizontalCapsuleInset * 2,
            height: size.height + Self.verticalOffset + Self.verticalCapsuleInset * 2,
        )
    }

    override public var accessibilityLabel: String? {
        get {
            if let axLabelPrefix, let text = self.text {
                return axLabelPrefix + text
            }
            return super.accessibilityLabel
        }
        set { super.accessibilityLabel = newValue }
    }

    override public var accessibilityTraits: UIAccessibilityTraits {
        get {
            var axTraits = super.accessibilityTraits
            if onTap != nil {
                axTraits.insert(.button)
            }
            return axTraits
        }
        set {
            super.accessibilityTraits = newValue
        }
    }
}
