import Foundation

enum RenderWorkload: Sendable, Equatable {
    case staticFrame
    case spriteLoop(frameCount: Int, frameInterval: TimeInterval)
    case continuous
}

struct RenderCadence: Sendable, Equatable {
    let framesPerSecond: Int
    let scenePaused: Bool
    let viewPaused: Bool
}

enum RenderCadencePlanner {
    private static let suspendedCadence = RenderCadence(
        framesPerSecond: 5,
        scenePaused: true,
        viewPaused: true
    )
    // 静态帧不再暂停渲染（曾导致单帧状态/单帧精灵卡死后点击无反应），
    // 只降到 15fps 省电；effect 与状态切换仍能立即生效。
    private static let staticCadence = RenderCadence(
        framesPerSecond: 15,
        scenePaused: false,
        viewPaused: false
    )

    static func cadence(for workload: RenderWorkload, isVisible: Bool) -> RenderCadence {
        guard isVisible else {
            return suspendedCadence
        }

        switch workload {
        case .staticFrame:
            return staticCadence
        case .spriteLoop(let frameCount, let frameInterval):
            guard frameCount > 1 else {
                return staticCadence
            }
            let desiredFramesPerSecond: Double
            if frameInterval.isFinite, frameInterval > 0 {
                desiredFramesPerSecond = 1 / frameInterval
            } else {
                desiredFramesPerSecond = 60
            }
            let framesPerSecond = [5, 15, 30, 60]
                .first(where: { Double($0) >= desiredFramesPerSecond }) ?? 60
            return RenderCadence(
                framesPerSecond: framesPerSecond,
                scenePaused: false,
                viewPaused: false
            )
        case .continuous:
            return RenderCadence(
                framesPerSecond: 60,
                scenePaused: false,
                viewPaused: false
            )
        }
    }
}
