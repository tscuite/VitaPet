import CoreGraphics

struct SpriteScaleBaseline: Equatable, Sendable {
    let xScale: CGFloat
    let yScale: CGFloat

    init(xScale: CGFloat, yScale: CGFloat) {
        self.xScale = xScale == 0 ? 1 : xScale
        self.yScale = yScale == 0 ? 1 : yScale
    }

    func x(multiplier: CGFloat) -> CGFloat {
        xScale * multiplier
    }

    func y(multiplier: CGFloat) -> CGFloat {
        yScale * multiplier
    }
}
