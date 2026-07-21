import AppKit
import Foundation
import SpriteKit

public enum HorizontalDirection: Sendable {
    case left
    case right
}

@MainActor
public final class PetScene: SKScene, @unchecked Sendable {
    nonisolated public static let activeFramesPerSecond = 60

    public let petNode: SKSpriteNode

    private var manifest: SpriteManifest
    private let resourceBundle: Bundle
    private let animationKey = "RenderEngine.PetAnimation"
    private let effectKey = "RenderEngine.PetEffect"
    private let cadenceKey = "RenderEngine.RenderCadence"
    private var spritePackDirectory: URL?
    private var textureCache: [String: SKTexture] = [:]
    private var cachedPlaceholderTexture: SKTexture?
    private var renderWorkload: RenderWorkload = .staticFrame
    private var renderingVisible = true
    private var staticRedrawCoordinator = StaticRedrawCoordinator()
    private var animationGeneration: UInt = 0
    private var facingDirection: HorizontalDirection = .right

    public init(size: CGSize, manifest: SpriteManifest, resourceBundle: Bundle? = nil) {
        self.manifest = manifest
        self.resourceBundle = resourceBundle ?? RenderEngineResourceBundle.current
        self.petNode = SKSpriteNode(texture: nil, color: .clear, size: size)
        super.init(size: size)

        scaleMode = .resizeFill
        backgroundColor = .clear

        petNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        petNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(petNode)

        applyInitialTexture()
        pauseRendering()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        nil
    }

    public override func didMove(to view: SKView) {
        super.didMove(to: view)
        requestStaticRedrawIfNeeded()
    }

    public override func didFinishUpdate() {
        super.didFinishUpdate()

        guard let settleToken = staticRedrawCoordinator.didFinishUpdate() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let workload = self.renderWorkload
            let isVisible = self.renderingVisible
            guard self.staticRedrawCoordinator.settle(
                settleToken,
                workload: workload,
                isVisible: isVisible
            ) else {
                return
            }
            self.applyRenderCadence()
        }
    }

    public func playAnimation(for state: AnimationState) {
        if let plan = ActionComboPlanner.plan(for: state) {
            playActionCombo(plan)
            return
        }

        guard let config = animationConfig(for: state) else {
            return
        }

        let textures = loadTextures(from: config.frames)
        guard let firstTexture = textures.first else {
            return
        }

        petNode.removeAction(forKey: animationKey)
        petNode.removeAction(forKey: effectKey)
        petNode.removeAction(forKey: cadenceKey)
        resetNodeTransform()
        petNode.texture = firstTexture
        petNode.size = size  // Fill the scene, not the texture's natural size
        animationGeneration &+= 1
        let generation = animationGeneration

        let animation = SKAction.animate(
            with: textures,
            timePerFrame: config.frameInterval,
            resize: false,
            restore: false
        )
        let effect = visualEffect(for: state)
        let repeats = config.loop && state != .idle
        let restingWorkload: RenderWorkload = repeats
            ? .spriteLoop(frameCount: textures.count, frameInterval: config.frameInterval)
            : .staticFrame
        let activeWorkload: RenderWorkload = effect == nil
            ? .spriteLoop(frameCount: textures.count, frameInterval: config.frameInterval)
            : .continuous
        setRenderWorkload(activeWorkload)

        let action: SKAction
        if repeats {
            action = .repeatForever(animation)
        } else {
            action = animation
        }

        petNode.run(action, withKey: animationKey)

        // Add visual effects for states that reuse frames
        if let effect {
            petNode.run(effect, withKey: effectKey)
        }

        let shouldScheduleCadenceChange = !repeats || effect != nil
        if shouldScheduleCadenceChange {
            let animationDuration = repeats ? 0 : animation.duration
            let effectDuration = effect?.duration ?? 0
            let activeDuration = max(animationDuration, effectDuration)
            let settleCadence = SKAction.run { [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                self.setRenderWorkload(restingWorkload)
            }
            petNode.run(
                SKAction.sequence([
                    .wait(forDuration: activeDuration),
                    settleCadence
                ]),
                withKey: cadenceKey
            )
        }
    }

    public func playActionCombo(for state: AnimationState, count: Int = 1) {
        guard let plan = ActionComboPlanner.plan(for: state, count: count) else {
            playAnimation(for: state)
            return
        }

        playActionCombo(plan)
    }

    private func playActionCombo(_ plan: ActionComboPlan) {
        petNode.removeAction(forKey: animationKey)
        petNode.removeAction(forKey: effectKey)
        petNode.removeAction(forKey: cadenceKey)
        resetNodeTransform()

        let segmentActions = plan.segments.compactMap { actionSegment(for: $0) }
        guard segmentActions.isEmpty == false else {
            playAnimation(for: .idle)
            return
        }

        animationGeneration &+= 1
        let generation = animationGeneration
        setRenderWorkload(.continuous)

        if let firstState = plan.segments.first?.state,
           let firstConfig = animationConfig(for: firstState),
           let firstTexture = loadTextures(from: firstConfig.frames).first {
            petNode.texture = firstTexture
            petNode.size = size
        }

        let finish = SKAction.run { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.resetNodeTransform()
            self.applyInitialTexture()
            self.setRenderWorkload(.staticFrame)
        }
        petNode.run(SKAction.sequence(segmentActions + [finish]), withKey: animationKey)
    }

    private func actionSegment(for segment: ActionComboSegment) -> SKAction? {
        guard let config = animationConfig(for: segment.state) else {
            return nil
        }

        let textures = loadTextures(from: config.frames)
        guard textures.isEmpty == false else {
            return nil
        }

        let animation = SKAction.animate(
            with: textures,
            timePerFrame: config.frameInterval,
            resize: false,
            restore: false
        )
        let cycleDuration = max(Double(textures.count) * config.frameInterval, 0.01)
        let repeatCount = max(1, Int(ceil(segment.duration / cycleDuration)))
        let animationAction = repeatCount > 1 ? SKAction.repeat(animation, count: repeatCount) : animation
        let plannedAnimationDuration = cycleDuration * Double(repeatCount)
        if segment.duration > 0 {
            animationAction.speed = CGFloat(plannedAnimationDuration / segment.duration)
        }

        let motion = comboMotion(for: segment.state, duration: segment.duration)
            ?? visualEffect(for: segment.state)
            ?? SKAction.wait(forDuration: segment.duration)
        let timedMotion = SKAction.group([
            animationAction,
            motion,
            SKAction.wait(forDuration: segment.duration)
        ])

        return SKAction.sequence([
            SKAction.run { [weak self] in
                self?.resetNodeTransform()
            },
            timedMotion
        ])
    }

    private func animationConfig(for state: AnimationState) -> SpriteManifest.StateAnimation? {
        if let config = manifest.states[state.rawValue] {
            return config
        }

        for fallbackState in fallbackStates(for: state) where fallbackState != state {
            if let config = manifest.states[fallbackState.rawValue] {
                return config
            }
        }

        if state != .idle,
           let config = manifest.states[AnimationState.idle.rawValue] {
            return config
        }

        return manifest.states.values.first ?? SpritePackLoader.defaultAnimation(for: state)
    }

    private func fallbackStates(for state: AnimationState) -> [AnimationState] {
        switch state {
        case .danceCombo:
            return [.dance, .slide, .spin, .sparkle, .idle]
        case .somersaultCombo:
            return [.somersault, .angry, .roll, .idle]
        case .boxingCombo:
            return [.guardDuty, .pawReach, .punch, .angry, .idle]
        case .parkourCombo:
            return [.pounce, .slide, .roll, .spin, .idle]
        case .partyCombo:
            return [.sing, .dance, .sparkle, .cheer, .idle]
        case .trainingCombo:
            return [.guardDuty, .crouch, .pounce, .boxingCombo, .idle]
        case .joySpinCombo:
            return [.celebrate, .spin, .sparkle, .tailWag, .proud, .idle]
        case .lookAround:
            return [.walk, .idle]
        case .somersault:
            return [.angry, .wave, .idle]
        case .blink, .sniff, .tailWag:
            return [.idle]
        case .pawTap, .crouch, .meditate, .stargaze:
            return [.sit, .idle]
        case .pounce, .crawl, .slide:
            return [.walk, .run, .idle]
        case .nap, .dream:
            return [.sleep, .idle]
        case .beg, .nuzzle, .blush:
            return [.love, .shy, .sit, .idle]
        case .surprised:
            return [.react, .idle]
        case .proud, .sparkle:
            return [.cheer, .celebrate, .idle]
        case .melt:
            return [.sad, .sleep, .idle]
        case .sing:
            return [.chat, .idle]
        case .coffee:
            return [.drink, .eat, .idle]
        case .snack:
            return [.eat, .drink, .idle]
        case .pawReach:
            return [.wave, .idle]
        case .guardDuty:
            return [.alert, .idle]
        default:
            return [.idle]
        }
    }

    private func comboMotion(for state: AnimationState, duration: TimeInterval) -> SKAction? {
        let baseline = SpriteScaleBaseline(xScale: petNode.xScale, yScale: petNode.yScale)
        let baseX = baseline.xScale
        let direction = baseX < 0 ? -1.0 : 1.0

        switch state {
        case .dance:
            let step = max(duration / 4, 0.05)
            return SKAction.sequence([
                SKAction.group([
                    SKAction.rotate(toAngle: .pi / 18, duration: step, shortestUnitArc: true),
                    SKAction.moveBy(x: CGFloat(direction * 4), y: 2, duration: step)
                ]),
                SKAction.group([
                    SKAction.rotate(toAngle: -.pi / 18, duration: step, shortestUnitArc: true),
                    SKAction.moveBy(x: CGFloat(direction * -8), y: -1, duration: step)
                ]),
                SKAction.group([
                    SKAction.rotate(toAngle: .pi / 20, duration: step, shortestUnitArc: true),
                    SKAction.moveBy(x: CGFloat(direction * 8), y: 2, duration: step)
                ]),
                SKAction.group([
                    SKAction.rotate(toAngle: 0, duration: step, shortestUnitArc: true),
                    SKAction.moveBy(x: CGFloat(direction * -4), y: -3, duration: step)
                ])
            ])

        case .slide:
            return SKAction.sequence([
                SKAction.group([
                    SKAction.moveBy(x: CGFloat(direction * 14), y: -1, duration: duration * 0.48),
                    SKAction.scaleY(to: 0.92, duration: duration * 0.48)
                ]),
                SKAction.group([
                    SKAction.moveBy(x: CGFloat(direction * -14), y: 1, duration: duration * 0.52),
                    SKAction.scaleY(to: 1.0, duration: duration * 0.52)
                ])
            ])

        case .spin, .roll:
            return SKAction.rotate(byAngle: CGFloat(direction) * .pi * 2, duration: duration)

        case .somersault:
            let flipCount = max(
                1,
                Int(round(duration / ActionComboPlanner.somersaultPerFlipDuration))
            )
            let flip = SKAction.group([
                SKAction.rotate(byAngle: CGFloat(direction) * .pi * 2, duration: duration / Double(flipCount)),
                SKAction.sequence([
                    SKAction.scaleY(to: 0.86, duration: duration / Double(flipCount) * 0.35),
                    SKAction.scaleY(to: 1.14, duration: duration / Double(flipCount) * 0.35),
                    SKAction.scaleY(to: 1.0, duration: duration / Double(flipCount) * 0.30)
                ])
            ])
            return SKAction.repeat(flip, count: flipCount)

        case .punch:
            let jabOut = SKAction.group([
                SKAction.moveBy(x: CGFloat(direction * 7), y: 0, duration: duration * 0.35),
                SKAction.scaleX(to: baseX * 1.12, duration: duration * 0.35)
            ])
            let recoil = SKAction.group([
                SKAction.moveBy(x: CGFloat(direction * -7), y: 0, duration: duration * 0.30),
                SKAction.scaleX(to: baseX * 0.96, duration: duration * 0.30)
            ])
            let settle = SKAction.scaleX(to: baseX, duration: duration * 0.35)
            return SKAction.sequence([jabOut, recoil, settle])

        case .pawReach:
            return SKAction.sequence([
                SKAction.group([
                    SKAction.moveBy(x: CGFloat(direction * 5), y: 1, duration: duration * 0.45),
                    SKAction.scaleX(to: baseX * 1.08, duration: duration * 0.45)
                ]),
                SKAction.group([
                    SKAction.moveBy(x: CGFloat(direction * -5), y: -1, duration: duration * 0.55),
                    SKAction.scaleX(to: baseX, duration: duration * 0.55)
                ])
            ])

        case .guardDuty:
            return SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseX * 1.06, duration: duration * 0.35),
                    SKAction.scaleY(to: 0.96, duration: duration * 0.35)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseX * 0.98, duration: duration * 0.30),
                    SKAction.scaleY(to: 1.04, duration: duration * 0.30)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseX, duration: duration * 0.35),
                    SKAction.scaleY(to: 1.0, duration: duration * 0.35)
                ])
            ])

        case .pounce:
            return SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseX * 1.10, duration: duration * 0.25),
                    SKAction.scaleY(to: 0.84, duration: duration * 0.25)
                ]),
                SKAction.group([
                    SKAction.moveBy(x: CGFloat(direction * 8), y: 8, duration: duration * 0.40),
                    SKAction.scaleY(to: 1.12, duration: duration * 0.40)
                ]),
                SKAction.group([
                    SKAction.moveBy(x: CGFloat(direction * -8), y: -8, duration: duration * 0.35),
                    SKAction.scaleX(to: baseX, duration: duration * 0.35),
                    SKAction.scaleY(to: 1.0, duration: duration * 0.35)
                ])
            ])

        case .tailWag, .sparkle, .cheer, .proud, .blush, .sing, .pawTap:
            return visualEffect(for: state)

        case .danceCombo, .boxingCombo, .partyCombo, .parkourCombo, .trainingCombo, .joySpinCombo:
            let pulse = SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1.08), duration: duration * 0.35),
                    SKAction.scaleY(to: baseline.y(multiplier: 1.08), duration: duration * 0.35)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 0.96), duration: duration * 0.25),
                    SKAction.scaleY(to: baseline.y(multiplier: 0.96), duration: duration * 0.25)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1), duration: duration * 0.40),
                    SKAction.scaleY(to: baseline.y(multiplier: 1), duration: duration * 0.40)
                ])
            ])
            return pulse

        default:
            return nil
        }
    }

    private func visualEffect(for state: AnimationState) -> SKAction? {
        let baseline = SpriteScaleBaseline(xScale: petNode.xScale, yScale: petNode.yScale)

        switch state {
        case .stretch:
            // Horizontal stretch: squash and stretch
            let stretchOut = SKAction.scaleX(to: 1.3, duration: 0.4)
            let stretchBack = SKAction.scaleX(to: 1.0, duration: 0.3)
            let squashY = SKAction.scaleY(to: 0.85, duration: 0.4)
            let squashBack = SKAction.scaleY(to: 1.0, duration: 0.3)
            let xAction = SKAction.sequence([stretchOut, stretchBack])
            let yAction = SKAction.sequence([squashY, squashBack])
            return SKAction.group([xAction, yAction])

        case .yawn:
            // Vertical expand (mouth opening): scale up then back
            let openUp = SKAction.scaleY(to: 1.15, duration: 0.5)
            let settle = SKAction.scaleY(to: 0.95, duration: 0.3)
            let back = SKAction.scaleY(to: 1.0, duration: 0.2)
            return SKAction.sequence([openUp, settle, back])

        case .lookAround:
            // Quick look left-right by flipping xScale
            let currentX = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
            let lookLeft = SKAction.scaleX(to: -currentX, duration: 0.15)
            let pause1 = SKAction.wait(forDuration: 0.25)
            let lookRight = SKAction.scaleX(to: currentX, duration: 0.15)
            let pause2 = SKAction.wait(forDuration: 0.25)
            return SKAction.sequence([lookLeft, pause1, lookRight, pause2, lookLeft, pause1, lookRight])

        case .bounce:
            // Squash and stretch effect (no position movement to avoid conflict with window movement)
            let squash = SKAction.group([
                SKAction.scaleX(to: 1.2, duration: 0.08),
                SKAction.scaleY(to: 0.8, duration: 0.08)
            ])
            let stretch = SKAction.group([
                SKAction.scaleX(to: 0.9, duration: 0.08),
                SKAction.scaleY(to: 1.15, duration: 0.08)
            ])
            let settle = SKAction.group([
                SKAction.scaleX(to: 1.0, duration: 0.06),
                SKAction.scaleY(to: 1.0, duration: 0.06)
            ])
            let bounce1 = SKAction.sequence([squash, stretch, settle])
            let bounce2 = SKAction.sequence([
                SKAction.group([SKAction.scaleX(to: 1.1, duration: 0.06), SKAction.scaleY(to: 0.9, duration: 0.06)]),
                SKAction.group([SKAction.scaleX(to: 1.0, duration: 0.06), SKAction.scaleY(to: 1.0, duration: 0.06)])
            ])
            return SKAction.sequence([bounce1, .wait(forDuration: 0.05), bounce2])

        case .celebrate:
            // Spin + slight scale pulse
            let pulse = SKAction.sequence([
                SKAction.scale(to: 1.1, duration: 0.15),
                SKAction.scale(to: 1.0, duration: 0.15)
            ])
            return SKAction.repeat(pulse, count: 2)

        case .react:
            // Quick scale wobble (no position movement to avoid conflict with window movement)
            let wobble = SKAction.sequence([
                SKAction.scaleX(to: 0.9, duration: 0.04),
                SKAction.scaleX(to: 1.1, duration: 0.04),
                SKAction.scaleX(to: 1.0, duration: 0.04)
            ])
            return SKAction.repeat(wobble, count: 2)

        case .spin:
            return SKAction.rotate(byAngle: .pi * 2, duration: 0.5)

        case .love:
            let pulse = SKAction.sequence([
                SKAction.scale(to: 1.15, duration: 0.2),
                SKAction.scale(to: 1.0, duration: 0.2)
            ])
            return SKAction.repeat(pulse, count: 2)

        case .scared:
            let shake = SKAction.sequence([
                SKAction.scaleX(to: 0.95, duration: 0.03),
                SKAction.scaleX(to: 1.05, duration: 0.03),
                SKAction.scaleX(to: 1.0, duration: 0.03)
            ])
            return SKAction.repeat(shake, count: 4)

        case .dance:
            let currentX = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
            let sway = SKAction.sequence([
                SKAction.scaleX(to: -currentX, duration: 0.2),
                SKAction.scaleX(to: currentX, duration: 0.2)
            ])
            return SKAction.repeat(sway, count: 2)

        case .blink:
            return SKAction.sequence([
                SKAction.scaleY(to: 0.96, duration: 0.08),
                SKAction.scaleY(to: 1.0, duration: 0.10)
            ])

        case .sniff:
            let sniff = SKAction.sequence([
                SKAction.moveBy(x: 2, y: 0, duration: 0.08),
                SKAction.moveBy(x: -2, y: 0, duration: 0.08)
            ])
            return SKAction.repeat(sniff, count: 3)

        case .tailWag:
            let wag = SKAction.sequence([
                SKAction.scaleX(to: baseline.x(multiplier: 1.04), duration: 0.08),
                SKAction.scaleX(to: baseline.x(multiplier: 0.96), duration: 0.08)
            ])
            return SKAction.sequence([
                SKAction.repeat(wag, count: 5),
                SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0)
            ])

        case .pawTap:
            let tap = SKAction.sequence([
                SKAction.moveBy(x: 0, y: -2, duration: 0.06),
                SKAction.moveBy(x: 0, y: 2, duration: 0.08)
            ])
            return SKAction.repeat(tap, count: 3)

        case .pounce:
            let crouch = SKAction.group([
                SKAction.scaleX(to: baseline.x(multiplier: 1.08), duration: 0.10),
                SKAction.scaleY(to: 0.86, duration: 0.10)
            ])
            let leap = SKAction.group([
                SKAction.scaleX(to: baseline.x(multiplier: 0.94), duration: 0.16),
                SKAction.scaleY(to: 1.12, duration: 0.16),
                SKAction.moveBy(x: 0, y: 8, duration: 0.16)
            ])
            let land = SKAction.group([
                SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0.12),
                SKAction.scaleY(to: 1.0, duration: 0.12),
                SKAction.moveBy(x: 0, y: -8, duration: 0.12)
            ])
            return SKAction.sequence([crouch, leap, land])

        case .crouch:
            return SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1.10), duration: 0.20),
                    SKAction.scaleY(to: baseline.y(multiplier: 0.78), duration: 0.20),
                    SKAction.moveBy(x: 0, y: -4, duration: 0.20)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0),
                    SKAction.scaleY(to: baseline.y(multiplier: 1), duration: 0)
                ])
            ])

        case .crawl:
            let crawl = SKAction.sequence([
                SKAction.moveBy(x: 3, y: -1, duration: 0.12),
                SKAction.moveBy(x: -3, y: 1, duration: 0.12)
            ])
            return SKAction.repeat(crawl, count: 3)

        case .nap:
            let breathe = SKAction.sequence([
                SKAction.scaleY(to: 1.03, duration: 0.45),
                SKAction.scaleY(to: 1.0, duration: 0.45)
            ])
            return SKAction.repeat(breathe, count: 2)

        case .dream:
            return SKAction.sequence([
                SKAction.moveBy(x: 0, y: 3, duration: 0.35),
                SKAction.moveBy(x: 0, y: -3, duration: 0.35)
            ])

        case .beg, .nuzzle, .blush:
            let pulse = SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1.06), duration: 0.16),
                    SKAction.scaleY(to: baseline.y(multiplier: 1.06), duration: 0.16)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0.16),
                    SKAction.scaleY(to: baseline.y(multiplier: 1), duration: 0.16)
                ])
            ])
            return SKAction.repeat(pulse, count: 2)

        case .surprised:
            return SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 0.90), duration: 0.05),
                    SKAction.scaleY(to: 1.16, duration: 0.05),
                    SKAction.moveBy(x: 0, y: 5, duration: 0.05)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0.12),
                    SKAction.scaleY(to: 1.0, duration: 0.12),
                    SKAction.moveBy(x: 0, y: -5, duration: 0.12)
                ])
            ])

        case .proud:
            return SKAction.sequence([
                SKAction.scaleY(to: 1.10, duration: 0.18),
                SKAction.scaleY(to: 1.0, duration: 0.18)
            ])

        case .melt:
            return SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1.18), duration: 0.35),
                    SKAction.scaleY(to: baseline.y(multiplier: 0.70), duration: 0.35),
                    SKAction.moveBy(x: 0, y: -7, duration: 0.35)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0),
                    SKAction.scaleY(to: baseline.y(multiplier: 1), duration: 0)
                ])
            ])

        case .sing:
            let sing = SKAction.sequence([
                SKAction.rotate(toAngle: .pi / 18, duration: 0.12, shortestUnitArc: true),
                SKAction.rotate(toAngle: -.pi / 18, duration: 0.12, shortestUnitArc: true),
                SKAction.rotate(toAngle: 0, duration: 0.12, shortestUnitArc: true)
            ])
            return SKAction.repeat(sing, count: 2)

        case .meditate:
            return SKAction.sequence([
                SKAction.moveBy(x: 0, y: 4, duration: 0.45),
                SKAction.moveBy(x: 0, y: -4, duration: 0.45)
            ])

        case .coffee, .snack:
            return SKAction.sequence([
                SKAction.rotate(toAngle: -.pi / 24, duration: 0.12, shortestUnitArc: true),
                SKAction.rotate(toAngle: 0, duration: 0.16, shortestUnitArc: true)
            ])

        case .stargaze:
            return SKAction.sequence([
                SKAction.rotate(toAngle: .pi / 30, duration: 0.24, shortestUnitArc: true),
                SKAction.rotate(toAngle: 0, duration: 0.24, shortestUnitArc: true)
            ])

        case .sparkle:
            let sparkle = SKAction.sequence([
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1.10), duration: 0.10),
                    SKAction.scaleY(to: baseline.y(multiplier: 1.10), duration: 0.10)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 0.96), duration: 0.10),
                    SKAction.scaleY(to: baseline.y(multiplier: 0.96), duration: 0.10)
                ]),
                SKAction.group([
                    SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0.08),
                    SKAction.scaleY(to: baseline.y(multiplier: 1), duration: 0.08)
                ])
            ])
            return SKAction.repeat(sparkle, count: 2)

        case .slide:
            return SKAction.sequence([
                SKAction.moveBy(x: 10, y: -1, duration: 0.16),
                SKAction.moveBy(x: -10, y: 1, duration: 0.18)
            ])

        case .pawReach:
            return SKAction.sequence([
                SKAction.scaleX(to: baseline.x(multiplier: 1.08), duration: 0.16),
                SKAction.scaleX(to: baseline.x(multiplier: 1), duration: 0.14)
            ])

        case .guardDuty:
            let guardMotion = SKAction.sequence([
                SKAction.scaleY(to: 1.05, duration: 0.20),
                SKAction.scaleY(to: 1.0, duration: 0.20)
            ])
            return SKAction.repeat(guardMotion, count: 2)

        default:
            return nil
        }
    }

    private func resetNodeTransform() {
        switch facingDirection {
        case .left:
            petNode.xScale = -1
        case .right:
            petNode.xScale = 1
        }
        petNode.yScale = 1
        petNode.zRotation = 0
        petNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// 翻跟头各阶段时长（秒），方便 PetWindowController 同步窗口平移。
    public static let somersaultPrepDuration: TimeInterval = 0.18 + 0.35
    public static let somersaultPerFlipDuration = ActionComboPlanner.somersaultPerFlipDuration
    public static let somersaultSettleDuration: TimeInterval = 0.08 + 0.14
    /// 落地后到招手收势之间的停顿。
    public static let somersaultPrePunchPause: TimeInterval = 0.22
    /// 单段收势时长：招手摆动的「外摆 → 回摆 → 回正」，与 `somersaultPerJabDuration` 一致。
    public static let somersaultJabCount: Int = 3
    public static let somersaultPerJabDuration: TimeInterval = 0.12 + 0.11 + 0.12 + 0.17  // 0.52s
    public static let somersaultPunchComboDuration: TimeInterval =
        somersaultPrePunchPause
        + Double(somersaultJabCount) * somersaultPerJabDuration
        + 0.15

    public static func somersaultTotalDuration(count: Int) -> TimeInterval {
        let flips = max(1, min(count, 8))
        return somersaultPrepDuration
            + Double(flips) * somersaultPerFlipDuration
            + somersaultSettleDuration
            + somersaultPunchComboDuration
    }

    /// 招手式摆动：外展 → 反向轻带 → 回中立，总时长等于 `somersaultPerJabDuration`。
    private func somersaultWaveLikeGesture(bx: CGFloat, side: CGFloat, duration: TimeInterval) -> SKAction {
        let t1 = duration * 0.30
        let t2 = duration * 0.35
        let t3 = duration * 0.35
        let swayOut = SKAction.group([
            SKAction.rotate(toAngle: side * .pi / 10, duration: t1, shortestUnitArc: true),
            SKAction.scaleX(to: bx * 1.05, duration: t1),
            SKAction.scaleY(to: 1.05, duration: t1)
        ])
        swayOut.timingMode = .easeOut
        let swayBack = SKAction.group([
            SKAction.rotate(toAngle: -side * .pi / 12, duration: t2, shortestUnitArc: true),
            SKAction.scaleX(to: bx * 0.97, duration: t2),
            SKAction.scaleY(to: 0.99, duration: t2)
        ])
        swayBack.timingMode = .easeInEaseOut
        let settle = SKAction.group([
            SKAction.rotate(toAngle: 0, duration: t3, shortestUnitArc: true),
            SKAction.scaleX(to: bx, duration: t3),
            SKAction.scaleY(to: 1.0, duration: t3)
        ])
        settle.timingMode = .easeOut
        return SKAction.sequence([swayOut, swayBack, settle])
    }

    /// 翻跟头：准备与空翻同上，落地后用与 `wave` 相同的精灵姿 + 招手式侧摆收势（非冲拳）。
    /// 平移由 PetWindowController 用 `somersault*Duration` 常量驱动 NSWindow，造成「在屏幕上翻滚」的效果。
    public func playSomersault(count: Int) {
        let flips = max(1, min(count, 8))

        // 严肃皱眉表情：优先用 manifest 里的 somersault 帧（适配自定义 sprite pack），
        // 退回到 angry → idle，最后兜底硬编码 pet_angry_0（默认 cat 包）。
        let candidateNames: [String] = [
            manifest.states[AnimationState.somersault.rawValue]?.frames.first,
            manifest.states[AnimationState.angry.rawValue]?.frames.first,
            manifest.states[AnimationState.idle.rawValue]?.frames.first,
            "pet_angry_0"
        ].compactMap { $0 }

        let seriousTexture: SKTexture
        if let real = candidateNames.lazy.compactMap({ self.loadRealTexture(named: $0) }).first {
            seriousTexture = real
        } else {
            return
        }

        let waveTexture: SKTexture? = {
            guard let name = manifest.states[AnimationState.wave.rawValue]?.frames.first else { return nil }
            return loadRealTexture(named: name)
        }()

        petNode.removeAction(forKey: animationKey)
        petNode.removeAction(forKey: effectKey)
        petNode.removeAction(forKey: cadenceKey)
        resetNodeTransform()
        animationGeneration &+= 1
        let generation = animationGeneration

        petNode.texture = seriousTexture
        petNode.size = size
        setRenderWorkload(.continuous)

        let facingSign: CGFloat = petNode.xScale < 0 ? -1 : 1
        let facingScale = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
        let flipDirection: CGFloat = facingSign >= 0 ? -1 : 1  // 朝向决定翻滚方向

        // 准备：蓄力后倾 —— 略扁、拉高、角度稍大，再短暂屏息
        let rearUp = SKAction.group([
            SKAction.scaleX(to: facingSign * facingScale * 0.82, duration: 0.18),
            SKAction.scaleY(to: 1.22, duration: 0.18),
            SKAction.rotate(toAngle: flipDirection * .pi / 9, duration: 0.18, shortestUnitArc: true)
        ])
        rearUp.timingMode = .easeOut
        let braceHold = SKAction.wait(forDuration: 0.35)

        let bx = facingSign * facingScale
        let flipDur = Self.somersaultPerFlipDuration
        let quarter = flipDur * 0.25
        // 翻滚：旋转带缓动 + 四拍挤压拉伸，避免「纸片匀速转」的廉价感
        let tuckCycle = SKAction.sequence([
            SKAction.group([
                SKAction.scaleY(to: 0.84, duration: quarter),
                SKAction.scaleX(to: bx * 1.16, duration: quarter)
            ]),
            SKAction.group([
                SKAction.scaleY(to: 1.16, duration: quarter),
                SKAction.scaleX(to: bx * 0.88, duration: quarter)
            ]),
            SKAction.group([
                SKAction.scaleY(to: 0.88, duration: quarter),
                SKAction.scaleX(to: bx * 1.12, duration: quarter)
            ]),
            SKAction.group([
                SKAction.scaleY(to: 1.0, duration: quarter),
                SKAction.scaleX(to: bx, duration: quarter)
            ])
        ])
        let rotOnce = SKAction.rotate(byAngle: flipDirection * .pi * 2, duration: flipDur)
        rotOnce.timingMode = .easeInEaseOut
        let flipOnce = SKAction.group([rotOnce, tuckCycle])
        let flipSequence = SKAction.repeat(flipOnce, count: flips)

        // 落地：轻微着地挤压再弹回（仍保持面向 bx）
        let landSquash = SKAction.group([
            SKAction.scaleX(to: bx * 1.08, duration: 0.08),
            SKAction.scaleY(to: 0.88, duration: 0.08),
            SKAction.rotate(toAngle: 0, duration: 0.08, shortestUnitArc: true)
        ])
        landSquash.timingMode = .easeIn
        let settle = SKAction.group([
            SKAction.scaleX(to: bx, duration: 0.14),
            SKAction.scaleY(to: 1.0, duration: 0.14)
        ])
        settle.timingMode = .easeOut
        let landing = SKAction.sequence([landSquash, settle])

        let adoptWaveTexture = SKAction.run { [weak self] in
            guard let self, let waveTexture else { return }
            self.petNode.texture = waveTexture
        }
        let restoreSeriousTexture = SKAction.run { [weak self] in
            guard let self else { return }
            self.petNode.texture = seriousTexture
        }

        // 收势：`wave` 精灵 + 左右交替的招手摆动（与单段时长常量一致）
        var waveSegments: [SKAction] = []
        for i in 0..<Self.somersaultJabCount {
            let side: CGFloat = (i % 2 == 0) ? 1 : -1
            waveSegments.append(somersaultWaveLikeGesture(bx: bx, side: side, duration: Self.somersaultPerJabDuration))
        }
        let punchCombo = SKAction.sequence(
            [SKAction.wait(forDuration: Self.somersaultPrePunchPause)]
                + [adoptWaveTexture]
                + waveSegments
                + [SKAction.wait(forDuration: 0.15), restoreSeriousTexture]
        )

        let finish = SKAction.run { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.resetNodeTransform()
            self.setRenderWorkload(.staticFrame)
        }
        let full = SKAction.sequence([rearUp, braceHold, flipSequence, landing, punchCombo, finish])
        petNode.run(full, withKey: animationKey)
    }

    public func setFacing(_ direction: HorizontalDirection) {
        facingDirection = direction
        let currentScale = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
        petNode.xScale = direction == .left ? -currentScale : currentScale
        requestStaticRedrawIfNeeded()
    }

    public func setRotation(_ angle: CGFloat) {
        petNode.zRotation = angle
        requestStaticRedrawIfNeeded()
    }

    public func pauseRendering() {
        setRenderWorkload(.staticFrame)
    }

    public func resumeRendering() {
        setRenderWorkload(.continuous)
    }

    public func setRenderingVisible(_ isVisible: Bool) {
        guard renderingVisible != isVisible else { return }
        renderingVisible = isVisible
        requestStaticRedrawIfNeeded()
    }

    public func refreshStaticFrame() {
        requestStaticRedrawIfNeeded()
    }

    var targetRenderCadence: RenderCadence {
        RenderCadencePlanner.cadence(for: renderWorkload, isVisible: renderingVisible)
    }

    private func setRenderWorkload(_ workload: RenderWorkload) {
        renderWorkload = workload
        requestStaticRedrawIfNeeded()
    }

    private func applyRenderCadence() {
        let cadence = staticRedrawCoordinator.cadenceOverride ?? targetRenderCadence
        isPaused = cadence.scenePaused

        guard let view else { return }
        view.preferredFramesPerSecond = cadence.framesPerSecond
        view.isPaused = cadence.viewPaused
    }

    private func requestStaticRedrawIfNeeded() {
        guard view != nil else {
            staticRedrawCoordinator.cancel()
            applyRenderCadence()
            return
        }
        staticRedrawCoordinator.requestRedraw(
            for: renderWorkload,
            isVisible: renderingVisible
        )
        applyRenderCadence()
    }

    /// 从当前 manifest 加载语言包文字
    public func loadLanguageTexts(key: String) -> [String]? {
        manifest.language?[key]
    }

    public func loadSpritePack(from directory: URL?) {
        if let directory,
           let manifest = try? SpritePackLoader.loadManifest(from: directory) {
            self.manifest = manifest
            self.spritePackDirectory = directory
        } else {
            manifest = SpritePackLoader.loadBundledManifest()
            spritePackDirectory = nil
        }

        textureCache.removeAll()
        cachedPlaceholderTexture = nil
        petNode.removeAction(forKey: animationKey)
        petNode.removeAction(forKey: effectKey)
        petNode.removeAction(forKey: cadenceKey)
        animationGeneration &+= 1
        applyInitialTexture()
        setRenderWorkload(.staticFrame)
    }

    private func applyInitialTexture() {
        let initialFrames = manifest.states[AnimationState.idle.rawValue]?.frames
            ?? manifest.states.values.first?.frames
            ?? []

        guard let firstFrame = initialFrames.first,
              let texture = loadTexture(named: firstFrame) else {
            return
        }

        petNode.texture = texture
        petNode.size = size  // Fill the scene
    }

    private func loadTextures(from frameNames: [String]) -> [SKTexture] {
        frameNames.compactMap { loadTexture(named: $0) }
    }

    private func loadTexture(named name: String) -> SKTexture? {
        if let cached = textureCache[name] {
            return cached
        }
        if let texture = loadRealTexture(named: name) {
            return texture
        }
        return placeholderTexture()
    }

    /// 只在真正能加载到资源时返回纹理，找不到返回 nil（不退回 placeholder），用于按 manifest 顺序级联回退。
    private func loadRealTexture(named name: String) -> SKTexture? {
        if let cached = textureCache[name] {
            return cached === cachedPlaceholderTexture ? nil : cached
        }

        if let spritePackDirectory {
            let textureURL = spritePackDirectory.appendingPathComponent("\(name).png")
            if let image = NSImage(contentsOf: textureURL) {
                let texture = SKTexture(image: image)
                texture.filteringMode = .nearest
                textureCache[name] = texture
                return texture
            }
            return nil
        }

        if let url = resourceBundle.url(forResource: name, withExtension: "png", subdirectory: "Resources") ??
                      resourceBundle.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let texture = SKTexture(image: image)
            texture.filteringMode = .nearest
            textureCache[name] = texture
            return texture
        }

        return nil
    }

    private func placeholderTexture() -> SKTexture {
        if let cached = cachedPlaceholderTexture {
            return cached
        }

        let imageSize = CGSize(width: 32, height: 32)
        let image = NSImage(size: imageSize)
        image.lockFocus()

        NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()

        NSColor.white.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 3
        cross.move(to: CGPoint(x: 6, y: 6))
        cross.line(to: CGPoint(x: 26, y: 26))
        cross.move(to: CGPoint(x: 26, y: 6))
        cross.line(to: CGPoint(x: 6, y: 26))
        cross.stroke()

        image.unlockFocus()

        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        cachedPlaceholderTexture = texture
        return texture
    }
}
