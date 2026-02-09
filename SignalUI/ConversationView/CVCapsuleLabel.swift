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

    private static let horizontalInset: CGFloat = 6
    private static let verticalInset: CGFloat = 1

    public init(
        attributedText: NSAttributedString,
        textColor: UIColor,
        font: UIFont?,
        highlightRange: NSRange,
        highlightFont: UIFont,
        axLabelPrefix: String?,
        isQuotedReply: Bool,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
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

        let horizontalInset: CGFloat
        if CurrentAppContext().isRTL {
            horizontalInset = -Self.horizontalInset
        } else {
            horizontalInset = Self.horizontalInset
        }

        let needsLeadingPadding = highlightRange.location == 0 && highlightRange.length == (text as NSString).length
        let glyphRange = layoutManager.glyphRange(forCharacterRange: highlightRange, actualCharacterRange: nil)

        let highlightColor = capsuleColor
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
            let hOffset = needsLeadingPadding ? horizontalInset : 0
            let roundedRect = rect.offsetBy(dx: hOffset, dy: -1).insetBy(dx: -Self.horizontalInset, dy: -Self.verticalInset)
            let path = UIBezierPath(roundedRect: roundedRect, cornerRadius: roundedRect.height / 2)
            highlightColor.setFill()
            path.fill()
        }

        let textOrigin = needsLeadingPadding ? CGPoint(x: .zero + horizontalInset, y: .zero) : CGPoint.zero
        let range = NSRange(location: 0, length: textStorage.length)
        layoutManager.drawGlyphs(forGlyphRange: range, at: textOrigin)
    }

    public class func measureLabel(config: CVLabelConfig, maxWidth: CGFloat) -> CGSize {
        let capsuleHPadding = horizontalInset * 2
        let capsuleVPadding = verticalInset * 2
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
        return CGSize(
            width: size.width + Self.horizontalInset * 2,
            height: size.height + Self.verticalInset * 2,
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
}
