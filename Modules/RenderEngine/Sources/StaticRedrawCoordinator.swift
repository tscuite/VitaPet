import Foundation

struct StaticRedrawCoordinator: Sendable {
    struct Generation: Sendable, Equatable {
        fileprivate let rawValue: UInt
    }

    struct SettleToken: Sendable, Equatable {
        fileprivate let generation: Generation
    }

    private var nextGeneration: UInt = 0
    private var currentGeneration: Generation?
    private var observedUpdateCycles = 0
    private var scheduledGeneration: Generation?

    var cadenceOverride: RenderCadence? {
        guard currentGeneration != nil else { return nil }
        return RenderCadence(framesPerSecond: 60, scenePaused: false, viewPaused: false)
    }

    @discardableResult
    mutating func requestRedraw(
        for workload: RenderWorkload,
        isVisible: Bool
    ) -> Generation? {
        guard workload.isStatic, isVisible else {
            cancel()
            return nil
        }

        nextGeneration &+= 1
        let generation = Generation(rawValue: nextGeneration)
        currentGeneration = generation
        observedUpdateCycles = 0
        scheduledGeneration = nil
        return generation
    }

    mutating func cancel() {
        currentGeneration = nil
        observedUpdateCycles = 0
        scheduledGeneration = nil
    }

    mutating func didFinishUpdate() -> SettleToken? {
        guard let currentGeneration, scheduledGeneration == nil else { return nil }

        observedUpdateCycles += 1
        guard observedUpdateCycles >= 2 else { return nil }

        scheduledGeneration = currentGeneration
        return SettleToken(generation: currentGeneration)
    }

    mutating func settle(
        _ token: SettleToken,
        workload: RenderWorkload,
        isVisible: Bool
    ) -> Bool {
        guard workload.isStatic, isVisible else {
            cancel()
            return false
        }
        guard currentGeneration == token.generation,
              scheduledGeneration == token.generation else {
            return false
        }

        cancel()
        return true
    }
}

private extension RenderWorkload {
    var isStatic: Bool {
        switch self {
        case .staticFrame:
            return true
        case .spriteLoop(let frameCount, _):
            return frameCount <= 1
        case .continuous:
            return false
        }
    }
}
