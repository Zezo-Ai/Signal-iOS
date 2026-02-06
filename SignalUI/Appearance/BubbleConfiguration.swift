//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public struct BubbleStrokeConfiguration {
    public let color: UIColor
    public let width: CGFloat

    public init(color: UIColor, width: CGFloat) {
        self.color = color
        self.width = width
    }
}

public struct BubbleCornerConfiguration {
    public let sharpCorners: OWSDirectionalRectCorner
    public let sharpCornerRadius: CGFloat
    public let wideCornerRadius: CGFloat

    public init(sharpCorners: OWSDirectionalRectCorner, sharpCornerRadius: CGFloat, wideCornerRadius: CGFloat) {
        self.sharpCorners = sharpCorners
        self.sharpCornerRadius = sharpCornerRadius
        self.wideCornerRadius = wideCornerRadius
    }

    public init(cornerRadius: CGFloat) {
        self.sharpCorners = []
        self.sharpCornerRadius = 0
        self.wideCornerRadius = cornerRadius
    }
}
