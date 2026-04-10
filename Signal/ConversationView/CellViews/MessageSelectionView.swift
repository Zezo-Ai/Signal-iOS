//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class MessageSelectionView: ManualLayoutView {

    var isSelected: Bool = false {
        didSet {
            selectedView.isHidden = !isSelected
            unselectedView.isHidden = isSelected
        }
    }

    init() {
        super.init(name: "MessageSelectionView")

        // `checkCircleFill` has some margins baked and needs to be 24 x 24 pts.
        addSubviewToCenterOnSuperview(selectedView, size: .square(Self.circleDiameter))

        // This view has a centered stroke and needs to be made smaller by
        // the amount of space baked into the `checkCircleFill` and half of the stroke line width.
        let ringDiameter = Self.circleDiameter - Self.emptyCheckmarkStrokeLineWidth / 2 - 1
        addSubviewToCenterOnSuperview(unselectedView, size: .square(ringDiameter))

        addLayoutBlock { view in
            guard let selectionView = view as? MessageSelectionView else { return }
            selectionView.checkmarkIcon.frame = selectionView.selectedView.bounds.insetBy(dx: 2, dy: 2)
        }

        selectedView.isHidden = !isSelected
    }

    static var preferredSize: CGSize {
        CGSize(square: ConversationStyle.selectionViewWidth)
    }

    private static var circleDiameter: CGFloat {
        // 22 dp as per spec
        ConversationStyle.selectionViewWidth - 2
    }

    private static var emptyCheckmarkStrokeLineWidth: CGFloat { 2 }

    private lazy var checkmarkIcon: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "check-20"))
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .white
        return imageView
    }()

    private lazy var selectedView: UIView = {
        let circleView = CircleView(frame: .init(origin: .zero, size: .square(MessageSelectionView.circleDiameter)))
        circleView.addSubview(checkmarkIcon)
        return circleView
    }()

    private lazy var unselectedView: UIView = {
        let circleView = RingView()
        circleView.lineWidth = MessageSelectionView.emptyCheckmarkStrokeLineWidth
        return circleView
    }()

    func updateStyle(conversationStyle: ConversationStyle) {
        AssertIsOnMainThread()

        selectedView.backgroundColor = conversationStyle.chatColorValue.asChatUIElementTintColor()
        unselectedView.tintColor = UIColor.Signal.tertiaryLabel
    }

    private class RingView: UIView {

        override class var layerClass: AnyClass {
            CAShapeLayer.self
        }

        private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

        var lineWidth: CGFloat {
            get {
                shapeLayer.lineWidth
            }
            set {
                shapeLayer.lineWidth = newValue
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)

            shapeLayer.fillColor = UIColor.clear.cgColor
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var frame: CGRect {
            didSet {
                if bounds.size != oldValue.size {
                    updatePath()
                }
            }
        }

        override var tintColor: UIColor! {
            didSet {
                updateColor()
            }
        }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            updateColor()
        }

        private func updatePath() {
            shapeLayer.path = UIBezierPath(ovalIn: layer.bounds).cgPath
        }

        private func updateColor() {
            shapeLayer.strokeColor = tintColor?.cgColor
        }
    }
}
