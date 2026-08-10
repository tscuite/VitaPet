import AppKit

@MainActor
public final class BehaviorEngine {
    private let manifest: BehaviorManifest
    private let screenBounds: () -> NSRect
    private var cursorTrackingTimer: Timer?
    private var currentMovement: MovementState?
    private var cursorTrackingPetCenter: (@MainActor @Sendable () -> NSPoint)?
    private var cursorTrackingOnFlip: (@MainActor @Sendable (Bool) -> Void)?
    private var cursorTrackingOnReact: (@MainActor @Sendable () -> Void)?
    private var cursorTrackingContext: CursorTrackingContext?
    private var cursorTrackingReactThreshold: CGFloat = 0
    private let cursorTrackingReactInterval: TimeInterval = 60

    private enum HideDirection {
        case left
        case right
        case top
        case bottom
    }

    private final class CursorTrackingContext: @unchecked Sendable {
        var lastReactTime: Date
        var cursorWasOutsideReactZone: Bool

        init(lastReactTime: Date, cursorWasOutsideReactZone: Bool) {
            self.lastReactTime = lastReactTime
            self.cursorWasOutsideReactZone = cursorWasOutsideReactZone
        }
    }

    private final class MovementState: @unchecked Sendable {
        let id: UUID
        var timer: Timer?
        var completionWorkItem: DispatchWorkItem?
        var completion: (@MainActor @Sendable () -> Void)?

        init(
            id: UUID,
            completionWorkItem: DispatchWorkItem? = nil,
            completion: (@MainActor @Sendable () -> Void)? = nil
        ) {
            self.id = id
            self.completionWorkItem = completionWorkItem
            self.completion = completion
        }

        func cancel() {
            timer?.invalidate()
            timer = nil
            completionWorkItem?.cancel()
            completionWorkItem = nil
        }

        deinit {
            cancel()
        }

        @MainActor
        func finish() {
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    nonisolated private static let frameRate: TimeInterval = 60
    nonisolated private static let frameInterval: TimeInterval = 1.0 / frameRate
    nonisolated private static let epsilonDistance: CGFloat = 0.1

    public var onDetectWindows: (@MainActor @Sendable () -> [CGRect])?
    public var onRotate: (@MainActor @Sendable (CGFloat) -> Void)?
    public var onAnimationChange: (@MainActor @Sendable (String) -> Void)?

    public init(manifest: BehaviorManifest, screenBounds: @escaping () -> NSRect) {
        self.manifest = manifest
        self.screenBounds = screenBounds
    }

    public func executeBehavior(
        _ name: String,
        currentPosition: NSPoint,
        petSize: CGFloat,
        trackingTarget: (@MainActor @Sendable () -> NSPoint?)? = nil,
        otherPetPositions: (() -> [NSPoint])? = nil,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void,
        onLand: (@MainActor @Sendable () -> Void)? = nil
    ) {
        cancelCurrentBehavior()

        guard let definition = behaviorDefinition(for: name) else {
            onComplete()
            return
        }

        switch definition.type {
        case .move:
            executeMove(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                otherPetPositions: otherPetPositions,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .jump:
            executeJump(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                otherPetPositions: otherPetPositions,
                onMove: onMove,
                onFlip: onFlip,
                onLand: onLand,
                onComplete: onComplete
            )
        case .chase:
            executeChase(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                trackingTarget: trackingTarget,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .hide:
            executeHide(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .windowSit:
            executeWindowSit(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .windowClimb:
            executeWindowClimb(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .circuit:
            executeCircuit(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        default:
            onComplete()
        }
    }

    public func cancelCurrentBehavior() {
        guard let movement = currentMovement else {
            return
        }
        movement.cancel()
        currentMovement = nil
        onRotate?(0)
    }

    public func stopCurrentBehavior() {
        cancelCurrentBehavior()
    }

    private func executeMove(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        otherPetPositions: (() -> [NSPoint])?,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let targetPoint = calculatedTargetPoint(
            definition: definition,
            currentPosition: currentPosition,
            petSize: petSize
        ) else {
            onComplete()
            return
        }
        let adjustedTarget = adjustedTargetPoint(
            from: targetPoint,
            petSize: petSize,
            otherPetPositions: otherPetPositions
        )

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if adjustedTarget.x < currentPosition.x {
                onFlip(true)
            } else if adjustedTarget.x > currentPosition.x {
                onFlip(false)
            }
        }

        let distance = movementDistance(from: currentPosition, to: adjustedTarget)
        guard distance > 0 else {
            onMove(currentPosition, 0)
            onComplete()
            return
        }

        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)
        runLinearMovement(
            movementID: movementID,
            from: currentPosition,
            to: adjustedTarget,
            speed: max(definition.speed ?? 1.0, 1.0),
            onMove: { point in
                onMove(point, 0)
            },
            onComplete: {}
        )
    }

    private func executeJump(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        otherPetPositions: (() -> [NSPoint])?,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onLand: (@MainActor @Sendable () -> Void)? = nil,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let targetPoint = calculatedTargetPoint(
            definition: definition,
            currentPosition: currentPosition,
            petSize: petSize
        ) else {
            onComplete()
            return
        }
        let adjustedTarget = adjustedTargetPoint(
            from: targetPoint,
            petSize: petSize,
            otherPetPositions: otherPetPositions
        )

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if adjustedTarget.x < currentPosition.x {
                onFlip(true)
            } else if adjustedTarget.x > currentPosition.x {
                onFlip(false)
            }
        }

        let distance = movementDistance(from: currentPosition, to: adjustedTarget)
        let speed = max(definition.speed ?? 1.0, 1.0)
        let jumpHeight = definition.jumpHeight ?? 0

        guard distance > 0 else {
            onMove(adjustedTarget, 0)
            onLand?()
            onComplete()
            return
        }

        let duration = distance / speed
        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)

        let startTime = ProcessInfo.processInfo.systemUptime
        currentMovement?.timer?.invalidate()
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let movement = self.currentMovement,
                      movement.id == movementID else {
                    return
                }

                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let progress = min(elapsed / duration, 1)
                let shouldFinish = progress >= 1
                let point: NSPoint
                if shouldFinish {
                    point = adjustedTarget
                } else {
                    let x = currentPosition.x + (adjustedTarget.x - currentPosition.x) * progress
                    let arcY = Double(currentPosition.y) + Double(adjustedTarget.y - currentPosition.y) * progress +
                        (jumpHeight * sin(progress * .pi))
                    point = NSPoint(x: x, y: CGFloat(arcY))
                }
                onMove(point, 0)

                if shouldFinish {
                    movement.timer?.invalidate()
                    movement.timer = nil
                    self.currentMovement = nil
                    onLand?()
                    movement.finish()
                }
            }
        }
        currentMovement?.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func executeChase(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        trackingTarget: (@MainActor @Sendable () -> NSPoint?)?,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        let speed = max(definition.speed ?? 1.0, 1.0)
        let stopDistance = definition.stopDistance ?? 0
        let maxDuration = max(definition.duration ?? 0.0, 0.01)

        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)

        final class TrackingState: @unchecked Sendable {
            var position: NSPoint
            var clock = ElapsedTickClock(maximumDelta: 0.1)

            init(_ position: NSPoint, timestamp: TimeInterval) {
                self.position = position
                clock.reset(at: timestamp)
            }
        }
        let startTime = ProcessInfo.processInfo.systemUptime
        let tracking = TrackingState(currentPosition, timestamp: startTime)

        currentMovement?.timer?.invalidate()
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let movement = self.currentMovement,
                      movement.id == movementID else {
                    return
                }

                let timestamp = ProcessInfo.processInfo.systemUptime
                let elapsed = timestamp - startTime
                let deltaTime = tracking.clock.advance(to: timestamp)
                if elapsed >= maxDuration {
                    movement.timer?.invalidate()
                    movement.timer = nil
                    self.currentMovement = nil
                    movement.finish()
                    return
                }

                let targetPosition = trackingTarget?() ?? NSEvent.mouseLocation
                let deltaX = targetPosition.x - tracking.position.x
                let deltaY = targetPosition.y - tracking.position.y
                let distanceToCursor = sqrt((deltaX * deltaX) + (deltaY * deltaY))

                if stopDistance > 0 && distanceToCursor <= stopDistance {
                    movement.timer?.invalidate()
                    movement.timer = nil
                    self.currentMovement = nil
                    movement.finish()
                    return
                }

                if let shouldFlip = definition.flipToDirection, shouldFlip {
                    if deltaX < 0 {
                        onFlip(true)
                    } else if deltaX > 0 {
                        onFlip(false)
                    }
                }

                guard distanceToCursor > 0 else {
                    return
                }

                let stepDistance = CGFloat(speed * deltaTime)
                if stepDistance <= 0 {
                    return
                }

                let ratio = min(stepDistance / distanceToCursor, 1)
                let rawX = tracking.position.x + (deltaX * ratio)
                let rawY = tracking.position.y + (deltaY * ratio)
                let nextPoint = self.clampPoint(NSPoint(x: rawX, y: rawY), for: petSize)

                guard abs(nextPoint.x - tracking.position.x) > Self.epsilonDistance ||
                      abs(nextPoint.y - tracking.position.y) > Self.epsilonDistance else {
                    return
                }

                tracking.position = nextPoint
                onMove(nextPoint, 0)
            }
        }

        currentMovement?.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func executeHide(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        let moveOutSpeed = max(definition.speed ?? 1.0, 1.0)
        let peekBackSpeed = max(definition.peekBackSpeed ?? 1.0, 1.0)
        let hideTime = max(definition.hideTime ?? 0.0, 0.0)

        guard let hiddenPoint = hiddenPoint(from: currentPosition, for: petSize, in: screenBounds()) else {
            onComplete()
            return
        }

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if hiddenPoint.x < currentPosition.x {
                onFlip(true)
            } else if hiddenPoint.x > currentPosition.x {
                onFlip(false)
            }
        }

        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)

        runLinearMovement(
            movementID: movementID,
            from: currentPosition,
            to: hiddenPoint,
            speed: moveOutSpeed,
            autoComplete: false,
            onMove: { point in
                onMove(point, 0)
            },
            onComplete: { [weak self] in
                let beginPeekBack: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self else {
                        return
                    }

                    self.runLinearMovement(
                        movementID: movementID,
                        from: hiddenPoint,
                        to: currentPosition,
                        speed: peekBackSpeed,
                        onMove: { point in
                            onMove(point, 0)
                        },
                        onComplete: {}
                    )
                }

                guard let self,
                      let movement = self.currentMovement,
                      movement.id == movementID else {
                    return
                }

                guard hideTime > 0 else {
                    beginPeekBack()
                    return
                }

                self.currentMovement?.timer?.invalidate()
                let timer = Timer(timeInterval: hideTime, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self,
                              let movement = self.currentMovement,
                              movement.id == movementID else {
                            return
                        }
                        movement.timer?.invalidate()
                        movement.timer = nil
                        beginPeekBack()
                    }
                }
                self.currentMovement?.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        )
    }

    private func executeWindowSit(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let windowFrame = nearestWindow(to: currentPosition, petSize: petSize) else {
            executeFallbackMove(
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
            return
        }

        let movementID = UUID()
        let speed = max(definition.speed ?? 60, 1.0)
        let sitPoint = clampPoint(
            NSPoint(x: windowFrame.midX - (petSize / 2), y: windowFrame.maxY),
            for: petSize
        )

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if sitPoint.x < currentPosition.x {
                onFlip(true)
            } else if sitPoint.x > currentPosition.x {
                onFlip(false)
            }
        }

        onAnimationChange?(definition.animation ?? "walk")
        currentMovement = MovementState(id: movementID, completion: onComplete)

        runLinearMovement(
            movementID: movementID,
            from: currentPosition,
            to: sitPoint,
            speed: speed,
            autoComplete: false,
            onMove: { point in
                onMove(point, 0)
            },
            onComplete: { [weak self] in
                guard let self else {
                    return
                }

                self.onAnimationChange?("sit")

                let sitDuration = max(definition.sitDuration ?? Double.random(in: 3...8), 0)
                self.scheduleMovementStep(movementID: movementID, delay: sitDuration) { [weak self] _ in
                    guard let self else {
                        return
                    }

                    let groundPoint = self.clampPoint(
                        NSPoint(x: sitPoint.x, y: self.screenBounds().minY),
                        for: petSize
                    )

                    self.onAnimationChange?("jump")
                    self.runLinearMovement(
                        movementID: movementID,
                        from: sitPoint,
                        to: groundPoint,
                        speed: speed,
                        onMove: { point in
                            onMove(point, 0)
                        },
                        onComplete: { [weak self] in
                            self?.onRotate?(0)
                            self?.onAnimationChange?("idle")
                        }
                    )
                }
            }
        )
    }

    private func executeWindowClimb(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let windowFrame = nearestWindow(to: currentPosition, petSize: petSize) else {
            executeFallbackMove(
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
            return
        }

        let movementID = UUID()
        let speed = max(definition.speed ?? 40, 1.0)
        let useLeftEdge = Bool.random()
        let edgeCenterX = useLeftEdge ? windowFrame.minX : windowFrame.maxX
        let edgeOriginX = edgeCenterX - (petSize / 2)
        let basePoint = clampPoint(NSPoint(x: edgeOriginX, y: windowFrame.minY), for: petSize)
        let climbTopPoint = clampPoint(NSPoint(x: edgeOriginX, y: windowFrame.maxY), for: petSize)

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if basePoint.x < currentPosition.x {
                onFlip(true)
            } else if basePoint.x > currentPosition.x {
                onFlip(false)
            }
        }

        onAnimationChange?(definition.animation ?? "walk")
        currentMovement = MovementState(id: movementID, completion: onComplete)

        runLinearMovement(
            movementID: movementID,
            from: currentPosition,
            to: basePoint,
            speed: speed,
            autoComplete: false,
            onMove: { point in
                onMove(point, 0)
            },
            onComplete: { [weak self] in
                guard let self,
                      let movement = self.currentMovement,
                      movement.id == movementID else {
                    return
                }

                self.onRotate?(useLeftEdge ? (.pi / 2) : (-.pi / 2))
                self.onAnimationChange?("climb")

                self.runLinearMovement(
                    movementID: movementID,
                    from: basePoint,
                    to: climbTopPoint,
                    speed: speed,
                    autoComplete: false,
                    onMove: { point in
                        onMove(point, 0)
                    },
                    onComplete: { [weak self] in
                        guard let self,
                              let movement = self.currentMovement,
                              movement.id == movementID else {
                            return
                        }

                        self.onRotate?(0)
                        self.onAnimationChange?("sit")

                        let sitDuration = max(definition.sitDuration ?? 3.0, 0)
                        self.scheduleMovementStep(movementID: movementID, delay: sitDuration) { [weak self] _ in
                            guard let self else {
                                return
                            }
                            let groundPoint = self.clampPoint(
                                NSPoint(x: climbTopPoint.x, y: self.screenBounds().minY),
                                for: petSize
                            )

                            self.onAnimationChange?("jump")
                            self.runLinearMovement(
                                movementID: movementID,
                                from: climbTopPoint,
                                to: groundPoint,
                                speed: speed,
                                onMove: { point in
                                    onMove(point, 0)
                                },
                                onComplete: { [weak self] in
                                    self?.onRotate?(0)
                                    self?.onAnimationChange?("idle")
                                }
                            )
                        }
                    }
                )
            }
        )
    }

    /// 绕屏跑：让宠物沿屏幕可视区域（内缩一个宠物尺寸）的矩形周长跑一整圈。
    /// 起点先跑到最近的角，再随机顺时针/逆时针绕回起点角，结束回正。
    /// 水平段旋转 0 并按方向翻转；竖直段旋转 ±90°（像沿屏幕边沿往上/下跑）。
    private func executeCircuit(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        let (minX, maxX, minY, maxY) = clampedRange(petSize: petSize)
        guard maxX > minX, maxY > minY else {
            onComplete()
            return
        }

        let corners = [
            NSPoint(x: minX, y: minY),  // 0: 左下
            NSPoint(x: maxX, y: minY),  // 1: 右下
            NSPoint(x: maxX, y: maxY),  // 2: 右上
            NSPoint(x: minX, y: maxY)   // 3: 左上
        ]

        // 最近角作为环路入口
        guard let startIndex = corners.indices.min(by: {
            movementDistance(from: currentPosition, to: corners[$0])
                < movementDistance(from: currentPosition, to: corners[$1])
        }) else {
            onComplete()
            return
        }

        let clockwise = Bool.random()
        // 闭环路点：[入口角 → 下一角 → ... → 回到入口角]，共 5 个点（4 段边）。
        let lapPoints: [NSPoint] = (0...4).map { step in
            let idx = clockwise
                ? (startIndex + step) % 4
                : (startIndex - step + 8) % 4
            return corners[idx]
        }

        let speed = max(definition.speed ?? 180, 1.0)
        let startCorner = corners[startIndex]

        struct CircuitSegment {
            let from: NSPoint
            let target: NSPoint
            let rotation: CGFloat
            let faceLeft: Bool?  // nil = 保持当前朝向（竖直段不额外翻转）
            let horizontal: Bool
        }

        // 逐段构建，并携带当前朝向，以便竖直段的旋转方向与朝向匹配
        // （xScale 翻转会影响 zRotation 的视觉方向，朝左时必须取反旋转角度）。
        var segments: [CircuitSegment] = []
        var facingRight = true
        var previous = currentPosition

        func addSegment(to target: NSPoint) {
            let dx = abs(target.x - previous.x)
            let dy = abs(target.y - previous.y)
            let horizontal = dx >= dy
            var rotation: CGFloat = 0
            var faceLeft: Bool? = nil

            if horizontal {
                if target.x < previous.x {
                    faceLeft = true
                    facingRight = false
                } else if target.x > previous.x {
                    faceLeft = false
                    facingRight = true
                }
            } else {
                let upward = target.y > previous.y
                // 朝右：上 +90°、下 -90°；朝左：上 -90°、下 +90°。
                rotation = (facingRight ? CGFloat.pi / 2 : -.pi / 2) * (upward ? 1 : -1)
            }

            segments.append(CircuitSegment(from: previous, target: target, rotation: rotation, faceLeft: faceLeft, horizontal: horizontal))
            previous = target
        }

        // 起跑段（current → 入口角）+ 环路四条边
        addSegment(to: startCorner)
        for target in lapPoints.dropFirst() {
            addSegment(to: target)
        }

        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)
        onAnimationChange?(definition.animation ?? "run")

        func runSegment(_ index: Int) {
            guard let movement = currentMovement, movement.id == movementID else {
                return
            }
            guard index < segments.count else {
                self.onRotate?(0)
                movement.timer = nil
                self.currentMovement = nil
                movement.finish()
                return
            }

            let segment = segments[index]
            self.onRotate?(segment.rotation)
            if let faceLeft = segment.faceLeft {
                onFlip(faceLeft)
            }

            self.runLinearMovement(
                movementID: movementID,
                from: segment.from,
                to: segment.target,
                speed: speed,
                autoComplete: false,
                onMove: { point in
                    onMove(point, 0)
                },
                onComplete: {
                    runSegment(index + 1)
                }
            )
        }

        runSegment(0)
    }

    private func runLinearMovement(
        movementID: UUID,
        from startPoint: NSPoint,
        to targetPoint: NSPoint,
        speed: Double,
        autoComplete: Bool = true,
        onMove: @escaping @MainActor @Sendable (NSPoint) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let movement = currentMovement, movement.id == movementID else {
            return
        }

        let distance = movementDistance(from: startPoint, to: targetPoint)
        guard distance > 0 else {
            onMove(targetPoint)
            if autoComplete {
                movement.timer = nil
                self.currentMovement = nil
                onComplete()
                movement.finish()
            } else {
                onComplete()
            }
            return
        }

        let duration = distance / CGFloat(speed)
        if duration <= 0 {
            onMove(targetPoint)
            if autoComplete {
                movement.timer = nil
                self.currentMovement = nil
                onComplete()
                movement.finish()
            } else {
                onComplete()
            }
            return
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        movement.timer?.invalidate()
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let activeMovement = self.currentMovement,
                      activeMovement.id == movementID else {
                    return
                }

                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let progress = min(elapsed / Double(duration), 1)
                let shouldFinish = progress >= 1
                let point: NSPoint
                if shouldFinish {
                    point = targetPoint
                } else {
                    let x = startPoint.x + (targetPoint.x - startPoint.x) * CGFloat(progress)
                    let y = startPoint.y + (targetPoint.y - startPoint.y) * CGFloat(progress)
                    point = NSPoint(x: x, y: y)
                }
                onMove(point)

                if shouldFinish {
                    activeMovement.timer?.invalidate()
                    activeMovement.timer = nil
                    if autoComplete {
                        self.currentMovement = nil
                        onComplete()
                        activeMovement.finish()
                    } else {
                        onComplete()
                    }
                }
            }
        }
        movement.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func calculatedTargetPoint(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat
    ) -> NSPoint? {
        guard let minDistance = definition.minDistance,
              let maxDistance = definition.maxDistance else {
            return nil
        }

        let distance = Double.random(in: min(minDistance, maxDistance)...max(minDistance, maxDistance))
        let xDirection = Bool.random() ? 1.0 : -1.0
        let yDirection = Bool.random() ? 1.0 : -1.0

        var targetPoint = currentPosition

        switch definition.targetMode {
        case "horizontal":
            targetPoint.x += xDirection * distance
        case "vertical":
            targetPoint.y += yDirection * distance
        default:
            targetPoint.x += xDirection * distance
            targetPoint.y += yDirection * distance
        }

        return clampPoint(targetPoint, for: petSize)
    }

    private func hiddenPoint(from currentPosition: NSPoint, for petSize: CGFloat, in bounds: NSRect) -> NSPoint? {
        guard let direction = nearestHideDirection(from: currentPosition, in: bounds, for: petSize) else {
            return nil
        }

        let halfHiddenSize = petSize / 2
        let maxX = bounds.maxX
        let minX = bounds.minX
        let maxY = bounds.maxY
        let minY = bounds.minY

        switch direction {
        case .left:
            return NSPoint(x: minX - halfHiddenSize, y: currentPosition.y)
        case .right:
            return NSPoint(x: maxX - halfHiddenSize, y: currentPosition.y)
        case .bottom:
            return NSPoint(x: currentPosition.x, y: minY - halfHiddenSize)
        case .top:
            return NSPoint(x: currentPosition.x, y: maxY - halfHiddenSize)
        }
    }

    private func nearestHideDirection(from position: NSPoint, in bounds: NSRect, for petSize: CGFloat) -> HideDirection? {
        let left = max(0, position.x - bounds.minX)
        let right = max(0, bounds.maxX - petSize - position.x)
        let bottom = max(0, position.y - bounds.minY)
        let top = max(0, bounds.maxY - petSize - position.y)

        let nearest = min(min(left, right), min(bottom, top))

        if nearest == left {
            return .left
        }
        if nearest == right {
            return .right
        }
        if nearest == bottom {
            return .bottom
        }
        if nearest == top {
            return .top
        }

        return .left
    }

    private func movementDistance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        let traveledX = end.x - start.x
        let traveledY = end.y - start.y
        return sqrt((traveledX * traveledX) + (traveledY * traveledY))
    }

    private func movementDuration(from start: NSPoint, to end: NSPoint, speed: Double) -> TimeInterval {
        let distance = movementDistance(from: start, to: end)
        guard distance > 0 else {
            return 0
        }
        return TimeInterval(distance / CGFloat(max(speed, 1.0)))
    }

    private func clampedRange(petSize: CGFloat) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let bounds = screenBounds()
        let minX = bounds.minX
        let maxX = max(bounds.minX, bounds.maxX - petSize)
        let minY = bounds.minY
        let maxY = max(bounds.minY, bounds.maxY - petSize)
        return (minX, maxX, minY, maxY)
    }

    private func clampPoint(_ point: NSPoint, for petSize: CGFloat) -> NSPoint {
        let (minX, maxX, minY, maxY) = clampedRange(petSize: petSize)
        return NSPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private func adjustedTargetPoint(
        from targetPoint: NSPoint,
        petSize: CGFloat,
        otherPetPositions: (() -> [NSPoint])?
    ) -> NSPoint {
        guard let otherPetPositions else {
            return targetPoint
        }
        let adjustedPoint = avoidOverlap(
            target: targetPoint,
            petSize: petSize,
            otherPositions: otherPetPositions()
        )
        return clampPoint(adjustedPoint, for: petSize)
    }

    private func avoidOverlap(
        target: NSPoint,
        petSize: CGFloat,
        otherPositions: [NSPoint]
    ) -> NSPoint {
        var adjusted = target
        for otherPos in otherPositions {
            let dx = adjusted.x - otherPos.x
            let dy = adjusted.y - otherPos.y
            let distance = sqrt(dx * dx + dy * dy)
            let minDistance = petSize * 1.2

            if distance < minDistance && distance > 0 {
                let pushX = dx / distance * minDistance
                let pushY = dy / distance * minDistance
                adjusted = NSPoint(x: otherPos.x + pushX, y: otherPos.y + pushY)
            } else if distance == 0 {
                adjusted = NSPoint(
                    x: adjusted.x + CGFloat.random(in: -petSize...petSize),
                    y: adjusted.y + CGFloat.random(in: -petSize...petSize)
                )
            }
        }
        return adjusted
    }

    private func executeFallbackMove(
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @MainActor @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let fallback = behaviorDefinition(for: "walk") else {
            onComplete()
            return
        }

        executeMove(
            definition: fallback,
            currentPosition: currentPosition,
            petSize: petSize,
            otherPetPositions: nil,
            onMove: onMove,
            onFlip: onFlip,
            onComplete: onComplete
        )
    }

    private func nearestWindow(to currentPosition: NSPoint, petSize: CGFloat) -> CGRect? {
        guard let windows = onDetectWindows?(), !windows.isEmpty else {
            return nil
        }

        let petCenter = CGPoint(x: currentPosition.x + (petSize / 2), y: currentPosition.y + (petSize / 2))
        return windows.min { lhs, rhs in
            distance(from: petCenter, to: lhs) < distance(from: petCenter, to: rhs)
        }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return sqrt((dx * dx) + (dy * dy))
    }

    private func scheduleMovementStep(
        movementID: UUID,
        delay: TimeInterval,
        action: @escaping (MovementState) -> Void
    ) {
        guard let movement = currentMovement, movement.id == movementID else {
            return
        }

        movement.completionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let activeMovement = self.currentMovement,
                  activeMovement.id == movementID else {
                return
            }

            activeMovement.completionWorkItem = nil
            action(activeMovement)
        }
        movement.completionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: workItem)
    }

    public func startCursorTracking(
        petCenter: @escaping @MainActor @Sendable () -> NSPoint,
        onFlip: @escaping @MainActor @Sendable (Bool) -> Void,
        onReact: @escaping @MainActor @Sendable () -> Void
    ) {
        stopCursorTracking()

        let reactDistance = behaviorDefinition(for: "lookAtCursor")?.reactDistance ?? 0
        cursorTrackingPetCenter = petCenter
        cursorTrackingOnFlip = onFlip
        cursorTrackingOnReact = onReact
        cursorTrackingReactThreshold = CGFloat(reactDistance)
        cursorTrackingContext = CursorTrackingContext(
            lastReactTime: .distantPast,
            cursorWasOutsideReactZone: true
        )

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performCursorTracking()
            }
        }
        cursorTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
        cursorTrackingPetCenter = nil
        cursorTrackingOnFlip = nil
        cursorTrackingOnReact = nil
        cursorTrackingContext = nil
        cursorTrackingReactThreshold = 0
    }

    private func performCursorTracking() {
        guard let centerProvider = cursorTrackingPetCenter,
              let flipHandler = cursorTrackingOnFlip else {
            return
        }

        let cursor = NSEvent.mouseLocation
        let center = centerProvider()

        if cursor.x < center.x {
            flipHandler(true)
        } else if cursor.x > center.x {
            flipHandler(false)
        }

        guard cursorTrackingReactThreshold > 0,
              let reactHandler = cursorTrackingOnReact,
              let context = cursorTrackingContext else {
            return
        }

        let deltaX = cursor.x - center.x
        let deltaY = cursor.y - center.y
        let distance = sqrt((deltaX * deltaX) + (deltaY * deltaY))

        guard distance < cursorTrackingReactThreshold else {
            context.cursorWasOutsideReactZone = true
            return
        }

        let now = Date()
        guard context.cursorWasOutsideReactZone,
              now.timeIntervalSince(context.lastReactTime) >= cursorTrackingReactInterval else {
            return
        }

        context.cursorWasOutsideReactZone = false
        context.lastReactTime = now
        reactHandler()
    }

    public func idleBehaviorWeights(for mood: String) -> [String: Int] {
        manifest.idleBehaviors[mood] ?? manifest.idleBehaviors["normal"] ?? [:]
    }

    public func pickIdleBehavior(for mood: String) -> String {
        let weights = idleBehaviorWeights(for: mood)
        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else {
            return ""
        }
        let pick = Int.random(in: 0..<totalWeight)
        var cumulative = 0

        for (name, weight) in weights {
            cumulative += weight
            if pick < cumulative {
                return name
            }
        }

        return weights.keys.first ?? ""
    }

    public func pickIdleBehavior(for mood: String, weightMultipliers: [String: Double]) -> String {
        var weights = idleBehaviorWeights(for: mood)

        for (behavior, multiplier) in weightMultipliers {
            if let weight = weights[behavior] {
                weights[behavior] = max(0, Int(Double(weight) * multiplier))
            }
        }

        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else {
            return ""
        }

        let pick = Int.random(in: 0..<totalWeight)
        var cumulative = 0

        for (name, weight) in weights {
            cumulative += weight
            if pick < cumulative {
                return name
            }
        }

        return weights.keys.first ?? ""
    }

    public func behaviorDefinition(for name: String) -> BehaviorDefinition? {
        manifest.behaviors[name]
    }

    public func allBehaviorNames() -> [String] {
        Array(manifest.behaviors.keys)
    }
}
