//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/**
 * Given an attributed string and a highlightRange, draws a colored capsule behind the characters in highlightRange.
 * The color of the capsule is determined by the textColor with opacity decreased.
 * highlightFont allows for the capsule text to be a different font (e.g. bold or not bold) from the rest of the attributed text.
 * Since we don't want the highlight range to wrap, but we may want the rest of the range to wrap, this class manually
 * truncates text longer than the given width and adds an ellipsis.
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
        self.textColor = textColor
        self.lineBreakMode = lineBreakMode
        self.numberOfLines = numberOfLines

        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapMemberLabel)))

        let attributedString = NSMutableAttributedString(attributedString: attributedText)
        attributedString.addAttribute(.font, value: self.font!, range: attributedText.entireRange)
        attributedString.addAttribute(.foregroundColor, value: textColor, range: attributedText.entireRange)

        // The highlighted text may have different font than the sender name
        attributedString.addAttribute(.font, value: highlightFont, range: highlightRange)
        self.attributedText = attributedString
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

    /// Takes an attributed string, its font, and color, and returns a new attributed string,
    /// truncated to fit within the max width, with an ellipsis appended to the end.
    private static func truncateStringUntilFits(
        string: NSAttributedString,
        maxWidth: CGFloat,
        font: UIFont,
        textColor: UIColor,
    ) -> NSAttributedString {
        guard string.size().width > maxWidth else {
            return string
        }

        let ellipsesUnicode = NSMutableAttributedString(string: "\u{2026}")
        ellipsesUnicode.addAttribute(.font, value: font, range: ellipsesUnicode.entireRange)
        ellipsesUnicode.addAttribute(
            .foregroundColor,
            value: textColor,
            range: ellipsesUnicode.entireRange,
        )
        let ellipsesWidth = ellipsesUnicode.size().width
        let newMaxWidth = maxWidth - ellipsesWidth

        let truncatedString: NSMutableAttributedString = NSMutableAttributedString(attributedString: string)

        // Since NSAttributedStrings count UTF-16 code points, we should
        // use rangeOfComposedCharacterSequences to delete the total range
        // for a single "visible" char to avoid breaking up emojis.
        while truncatedString.size().width > newMaxWidth {
            let totalCharRange = (truncatedString.string as NSString).rangeOfComposedCharacterSequences(
                for:
                NSRange(
                    location: truncatedString.length - 1,
                    length: 1,
                ),
            )
            truncatedString.deleteCharacters(in: totalCharRange)
        }

        truncatedString.append(ellipsesUnicode)
        return truncatedString
    }

    /// Takes an attributed string & its properties, and formats it correctly to prevent wrapping of the highlighted range.
    /// Any part of the attributed string outside of the highlight range can wrap as usual, but the highlighted range should
    /// stay on one line and truncate using truncateStringUntilFits().
    /// For example, "Jane (Engineer)" with () indicating the highlighted range, should either stay on one line width permitting, or become:
    ///
    /// "Jane
    /// (Engineer)"
    ///
    /// If the member label is too long for the given space on the next line it should become:
    ///
    /// "Jane
    /// (Eng...)"
    ///
    /// A long profile name might look like this:
    ///  "Jane Long Profile
    ///  Name (Engineer)"
    ///
    ///  or, if less wide,
    ///  "Jane
    ///  Long
    ///  Profile
    ///  Name
    ///  (Eng...)"
    ///
    ///  A truncated member label should always be on its own line.
    private static func formatCapsuleString(
        attributedString: NSAttributedString,
        highlightRange: NSRange,
        highlightFont: UIFont,
        textColor: UIColor,
        maxWidth: CGFloat,
    ) -> (NSAttributedString, NSRange)? {
        let totalStringWidth = attributedString.size().width
        let highlightedString = attributedString.attributedSubstring(from: highlightRange)
        let highlightedStringWidth = highlightedString.size().width

        let nonHighlightRange = NSRange(location: 0, length: highlightRange.location)
        let nonHighlightString = attributedString.attributedSubstring(from: nonHighlightRange)

        // TODO: dont use arbitrary spacing
        let breakString = NSAttributedString(string: "\n  ")

        // If highlight text width or total string width is greater than line width,
        // move highlight to the next line to avoid wrapping, and truncate it if needed.
        if highlightedStringWidth > maxWidth || totalStringWidth > maxWidth {
            let truncatedHighlightString = Self.truncateStringUntilFits(
                string: highlightedString,
                maxWidth: maxWidth,
                font: highlightFont,
                textColor: textColor,
            )

            if !nonHighlightString.isEmpty {
                let newTotalString = nonHighlightString + breakString + truncatedHighlightString
                let newHighlightRange = (newTotalString.string as NSString).range(of: truncatedHighlightString.string)
                return (newTotalString, newHighlightRange)
            }

            return (truncatedHighlightString, truncatedHighlightString.entireRange)
        }

        // Everything fits on one line! Return as-is.
        return (attributedString, highlightRange)
    }

    private func textContainerForFormattedString(
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage,
        size: CGSize,
    ) -> NSTextContainer {
        let textContainer = NSTextContainer(size: size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = self.numberOfLines
        textContainer.lineBreakMode = self.lineBreakMode
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        return textContainer
    }

    override public func drawText(in rect: CGRect) {
        guard let attributedText, let textColor else {
            return super.drawText(in: rect)
        }
        // We only need to offset the capsule & text horizontally if the edge of the view
        // might cut it off, (location starts at 0).
        var horizontalOffset: CGFloat = 0
        let needsHorizontalOffset = highlightRange.location == 0
        if needsHorizontalOffset {
            horizontalOffset = CurrentAppContext().isRTL ? -Self.horizontalOffset : Self.horizontalOffset
        }

        owsAssertDebug(numberOfLines == 0 || numberOfLines == 1, "CVCapsule wrapping behavior undefined")

        let maxWidth = rect.width - (2 * Self.horizontalCapsuleInset + horizontalOffset)
        let formattedStringData = CVCapsuleLabel.formatCapsuleString(
            attributedString: attributedText,
            highlightRange: highlightRange,
            highlightFont: highlightFont,
            textColor: textColor,
            maxWidth: maxWidth,
        )

        guard let (formattedAttributedString, newHighlightRange) = formattedStringData else {
            return super.drawText(in: rect)
        }

        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(attributedString: formattedAttributedString)
        let textContainer = textContainerForFormattedString(
            layoutManager: layoutManager,
            textStorage: textStorage,
            size: rect.size,
        )
        let highlightGlyphRange = layoutManager.glyphRange(forCharacterRange: newHighlightRange, actualCharacterRange: nil)
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

    override public var intrinsicContentSize: CGSize {
        return labelSize(maxWidth: .greatestFiniteMagnitude)
    }

    public static func measureLabel(
        attributedText: NSAttributedString,
        font: UIFont,
        highlightRange: NSRange,
        highlightFont: UIFont,
        isQuotedReply: Bool,
        maxWidth: CGFloat,
    ) -> CGSize {
        let label = CVCapsuleLabel(
            attributedText: attributedText,
            textColor: .black,
            font: UIFont.dynamicTypeFootnote.semibold(),
            highlightRange: highlightRange,
            highlightFont: highlightFont,
            axLabelPrefix: nil,
            isQuotedReply: isQuotedReply,
            onTap: nil,
        )
        return label.labelSize(maxWidth: maxWidth)
    }

    public func labelSize(maxWidth: CGFloat) -> CGSize {
        guard let attributedText, !attributedText.isEmpty else { return .zero }
        let horizontalOffset: CGFloat = (highlightRange.location == 0)
            ? (CurrentAppContext().isRTL ? -Self.horizontalOffset : Self.horizontalOffset)
            : 0

        let maxWidthMinusInsets = maxWidth - (horizontalOffset + Self.horizontalCapsuleInset * 2)

        owsAssertDebug(numberOfLines == 0 || numberOfLines == 1, "CVCapsule wrapping behavior undefined")

        let formattedStringData = CVCapsuleLabel.formatCapsuleString(
            attributedString: attributedText,
            highlightRange: highlightRange,
            highlightFont: highlightFont,
            textColor: textColor,
            maxWidth: maxWidthMinusInsets,
        )

        guard let (formattedAttributedString, newHighlightRange) = formattedStringData else {
            return .zero
        }

        let layoutManager = NSLayoutManager()
        let size = CGSize(width: maxWidthMinusInsets, height: .greatestFiniteMagnitude)
        let textStorage = NSTextStorage(attributedString: formattedAttributedString)
        let textContainer = textContainerForFormattedString(
            layoutManager: layoutManager,
            textStorage: textStorage,
            size: size,
        )

        if numberOfLines != 0 {
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let totalHeight = rect.height + Self.verticalOffset + Self.verticalCapsuleInset * 2
            let totalWidth = rect.width + horizontalOffset + Self.horizontalCapsuleInset * 2

            return CGSize(width: totalWidth, height: totalHeight)
        }

        // Sometimes the maxWidth is slightly different than the rect.width passed to drawText(),
        // which may cause the height to be too tall as the width wraps (creating extra whitespace).
        // Since we know the highlight text will always render on the bottom-most line, we can
        // stop the enumeration when we reach the highlight range and use that height to avoid extra whitespace.
        var totalHeight: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, usedRect, _, glyphRange, stop in
            let charRangeStart = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let charRangeEnd = layoutManager.characterIndexForGlyph(at: glyphRange.location + glyphRange.length - 1)

            let lineRange = NSRange(location: charRangeStart, length: charRangeEnd - charRangeStart + 1)
            totalHeight += usedRect.height

            if NSIntersectionRange(lineRange, newHighlightRange).length > 0 {
                stop.pointee = true
            }
        }

        totalHeight += Self.verticalOffset + Self.verticalCapsuleInset * 2
        let finalWidth = layoutManager.usedRect(for: textContainer).size.ceil.width + Self.horizontalCapsuleInset * 2 + horizontalOffset
        return CGSize(width: finalWidth, height: totalHeight)
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
