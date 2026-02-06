//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

public class CVWallpaperBlurView: ManualLayoutViewWithLayer, CVDimmableView {

    private var isPreview = false

    private weak var provider: WallpaperBlurProvider?

    private let imageView = CVImageView()
    private let maskLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    private var state: WallpaperBlurState?
    private var cornerConfig: BubbleCornerConfiguration?
    private var strokeConfig: BubbleStrokeConfiguration?

    init() {
        super.init(name: "CVWallpaperBlurView")

        clipsToBounds = true
        layer.zPosition = -1
        strokeLayer.fillColor = nil

        imageView.contentMode = .scaleAspectFill
        imageView.layer.mask = maskLayer
        imageView.layer.masksToBounds = true
        imageView.layer.addSublayer(strokeLayer)
        addSubview(imageView)

        owsAssertDebug(self.layer.delegate === self)
        maskLayer.disableAnimationsWithDelegate()
        strokeLayer.disableAnimationsWithDelegate()

        addLayoutBlock { [weak self] _ in
            self?.applyLayout()
        }
    }

    public func applyLayout() {
        UIView.performWithoutAnimation {
            imageView.frame = imageViewFrame
            maskLayer.frame = imageView.layer.bounds
            strokeLayer.frame = imageView.layer.bounds

            // Corners.
            if let cornerConfig {
                let sharpCorners = UIView.uiRectCorner(forOWSDirectionalRectCorner: cornerConfig.sharpCorners)
                let bubblePath = UIBezierPath.roundedRect(
                    maskFrame,
                    sharpCorners: sharpCorners,
                    sharpCornerRadius: cornerConfig.sharpCornerRadius,
                    wideCornerRadius: cornerConfig.wideCornerRadius,
                )
                maskLayer.path = bubblePath.cgPath

                // Need to apply corner rounding to `self` too.
                let layer = CAShapeLayer()
                layer.path = UIBezierPath.roundedRect(
                    bounds,
                    sharpCorners: sharpCorners,
                    sharpCornerRadius: cornerConfig.sharpCornerRadius,
                    wideCornerRadius: cornerConfig.wideCornerRadius,
                ).cgPath
                self.layer.mask = layer
            } else {
                maskLayer.path = CGPath(rect: maskFrame, transform: nil)

                layer.mask = nil
            }

            // Stroke.
            if let strokeConfig {
                strokeLayer.lineWidth = strokeConfig.width
                strokeLayer.strokeColor = strokeConfig.color.cgColor
                strokeLayer.path = maskLayer.path
                strokeLayer.isHidden = false
            } else {
                strokeLayer.isHidden = true
            }
        }
    }

    public func configureForPreview(
        cornerConfig: BubbleCornerConfiguration?,
        strokeConfig: BubbleStrokeConfiguration?,
    ) {
        resetContentAndConfiguration()

        self.isPreview = true
        self.cornerConfig = cornerConfig
        self.strokeConfig = strokeConfig

        updateIfNecessary()
    }

    public func configure(
        provider: WallpaperBlurProvider,
        cornerConfig: BubbleCornerConfiguration?,
        strokeConfig: BubbleStrokeConfiguration?,
    ) {
        resetContentAndConfiguration()

        self.isPreview = false
        // TODO: Observe provider changes.
        self.provider = provider
        self.cornerConfig = cornerConfig
        self.strokeConfig = strokeConfig

        updateIfNecessary()
    }

    public func updateIfNecessary() {
        guard !isPreview else {
            backgroundColor = Theme.backgroundColor
            imageView.isHidden = true
            return
        }
        guard let provider else {
            owsFailDebug("Missing provider.")
            resetContentAndConfiguration()
            return
        }
        guard let state = provider.wallpaperBlurState else {
            resetContent()
            return
        }
        guard state.id != self.state?.id else {
            ensurePositioning()
            return
        }
        self.state = state
        imageView.image = state.image
        imageView.isHidden = false

        ensurePositioning()
    }

    private var imageViewFrame: CGRect = .zero
    private var maskFrame: CGRect = .zero

    private func ensurePositioning() {
        guard !isPreview else {
            return
        }
        guard let state else {
            resetContent()
            return
        }
        let referenceView = state.referenceView
        imageViewFrame = convert(referenceView.bounds, from: referenceView)
        maskFrame = referenceView.convert(bounds, from: self)

        applyLayout()
    }

    private func resetContent() {
        backgroundColor = nil
        imageView.image = nil
        imageView.isHidden = false
        imageViewFrame = .zero
        maskFrame = .zero
        strokeLayer.isHidden = true
        state = nil
    }

    public func resetContentAndConfiguration() {
        isPreview = false
        provider = nil
        cornerConfig = nil

        resetContent()
    }

    // MARK: - CALayerDelegate

    override public func action(for layer: CALayer, forKey event: String) -> CAAction? {
        // Disable all implicit CALayer animations.
        NSNull()
    }

    // MARK: - CVDimmableView

    var dimmerColor: UIColor = .clear

    var dimsContent = false

    var backgroundLayer: CALayer? { imageView.layer }
}

// MARK: -

extension CVWallpaperBlurView: OWSBubbleViewHost {

    public var maskPath: UIBezierPath {
        guard let cornerConfig else {
            return UIBezierPath(rect: bounds)
        }
        let sharpCorners = UIView.uiRectCorner(forOWSDirectionalRectCorner: cornerConfig.sharpCorners)
        return UIBezierPath.roundedRect(
            bounds,
            sharpCorners: sharpCorners,
            sharpCornerRadius: cornerConfig.sharpCornerRadius,
            wideCornerRadius: cornerConfig.wideCornerRadius,
        )
    }

    public var bubbleReferenceView: UIView { self }
}
