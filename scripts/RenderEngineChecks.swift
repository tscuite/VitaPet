import AppKit
import Darwin
import Foundation
import RenderEngine
import SpriteKit

private func cpuSeconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

@main
struct RenderEngineChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let frame = NSRect(x: 180, y: 160, width: 72, height: 72)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = SKView(frame: NSRect(origin: .zero, size: frame.size))
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        panel.contentView = view
        panel.orderFrontRegardless()
        let manifest = SpritePackLoader.loadBundledManifest()
        precondition(manifest.states["idle"]?.frames.count == 1)
        let scene = PetScene(size: frame.size, manifest: manifest)
        let key = "RenderEngine.IdleBreathing"
        view.presentScene(scene)
        Task { @MainActor in
            @MainActor func settle() async { try! await Task.sleep(for: .milliseconds(350)) }
            @MainActor func checkIdle() {
                precondition(!view.isPaused && !scene.isPaused, "Visible idle must refresh its Metal drawable, not freeze an old frame")
                precondition(view.preferredFramesPerSecond == 15, "Only the static drawable refresh is reduced; compositor breathing stays smooth")
                precondition(view.layer?.animation(forKey: key) != nil, "Breathing must keep running in the compositor")
                precondition(view.layer?.magnificationFilter == .nearest, "Pixel art must retain nearest-neighbour scaling")
                precondition(scene.petNode.size == scene.size && abs(abs(scene.petNode.xScale) - 1) < 0.0001
                    && abs(scene.petNode.yScale - 1) < 0.0001, "Idle must restore the sprite's proportions after squashing effects")
                let transform = view.layer!.presentation()!.transform
                precondition(abs(transform.m11 - 1) < 0.0001 && (0.9799...1.0601).contains(transform.m22),
                    "Compositor breathing must not flatten or widen the pet")
            }
            await settle()
            precondition(!view.isPaused && view.preferredFramesPerSecond == 15, "Static fallback must remain responsive")
            scene.playAnimation(for: .idle)
            scene.playActionCombo(for: .danceCombo)
            await settle()
            precondition(!view.isPaused && view.preferredFramesPerSecond == 60 && view.layer?.animation(forKey: key) == nil,
                         "An old pending idle settle must not freeze a new combo")
            scene.playAnimation(for: .idle)
            precondition(!view.isPaused, "Idle must continue drawing the restored texture")
            await settle()
            checkIdle()
            let loop = view.layer!.animation(forKey: key) as! CABasicAnimation
            precondition(loop.duration == 1.6 && loop.autoreverses && loop.repeatCount.isInfinite)
            let high = (loop.fromValue as! NSValue).caTransform3DValue
            let low = (loop.toValue as! NSValue).caTransform3DValue
            precondition(abs(high.m22 - 1.06) < 0.0001 && abs(low.m22 - 0.98) < 0.0001)
            let center = (0.5 - view.layer!.anchorPoint.y) * view.bounds.height
            precondition(abs(center * high.m22 + high.m42 - center) < 0.0001, "Scale around the pet, not AppKit's bottom-left anchor")
            let y = view.layer!.presentation()!.transform.m22
            await settle()
            precondition(abs(view.layer!.presentation()!.transform.m22 - y) > 0.001, "A paused SKView must still visibly breathe")
            precondition(scene.petNode.texture != nil && scene.petNode.yScale == 1)
            let cpu = cpuSeconds(), start = ProcessInfo.processInfo.systemUptime
            try! await Task.sleep(for: .seconds(8))
            print(String(format: "Single-frame idle CPU: %.2f%% (diagnostic, not a CI threshold)",
                (cpuSeconds() - cpu) / (ProcessInfo.processInfo.systemUptime - start) * 100))
            checkIdle()
            let originalOrigin = panel.frame.origin
            for screen in NSScreen.screens {
                panel.setFrameOrigin(screen.visibleFrame.origin)
                await settle()
                checkIdle()
                if let metal = view.layer as? CAMetalLayer {
                    let pixels = view.bounds.width * panel.backingScaleFactor
                    precondition(abs(metal.drawableSize.width - pixels) < 1
                        && abs(metal.drawableSize.height - pixels) < 1, "Cross-display moves must preserve the drawable's aspect ratio and backing scale")
                }
            }
            panel.setFrameOrigin(originalOrigin)
            await settle()

            scene.playAnimation(for: .stretch)
            try! await Task.sleep(for: .milliseconds(200))
            precondition(scene.petNode.yScale < 0.98, "Exercise an actual squashing effect before interrupting it")
            scene.playAnimation(for: .idle)
            await settle()
            checkIdle()
            let beginTime = view.layer!.animation(forKey: key)!.beginTime
            precondition(scene.setFacing(.left))
            precondition(!view.isPaused, "Facing changes must redraw even during composited idle")
            await settle()
            checkIdle()
            precondition(scene.petNode.xScale < 0 && view.layer!.animation(forKey: key)!.beginTime == beginTime,
                         "Redraw must not restart the breathing cycle")

            scene.setRotation(.pi / 8)
            precondition(!view.isPaused && view.preferredFramesPerSecond == 60 && view.layer!.animation(forKey: key) == nil,
                         "Rotation returns to full-cadence SpriteKit, preserving transform order")
            await settle()
            precondition(abs(scene.petNode.zRotation - .pi / 8) < 0.0001)
            scene.playAnimation(for: .idle)
            await settle()
            checkIdle()
            scene.resumeRendering() // Same wake-up used by real mouse-down/drag/game entry points.
            precondition(!view.isPaused && !scene.isPaused && view.layer!.animation(forKey: key) == nil)
            precondition(scene.petNode.action(forKey: "RenderEngine.PetEffect") != nil, "Waking without an immediate state change must not lose breathing")
            scene.playAnimation(for: .react)
            await settle()
            precondition(view.layer!.animation(forKey: key) == nil, "Actions must not inherit the idle transform")

            scene.playAnimation(for: .idle)
            await settle()
            scene.setRenderingVisible(false)
            precondition(view.isPaused && view.layer!.animation(forKey: key) == nil, "Hidden pets must stop both renderers")
            scene.setRenderingVisible(true)
            await settle()
            checkIdle()

            scene.size = NSSize(width: 96, height: 96)
            view.setFrameSize(scene.size)
            scene.petNode.position = CGPoint(x: 48, y: 48)
            scene.petNode.size = scene.size
            scene.refreshStaticFrame()
            precondition(view.layer!.animation(forKey: key) == nil && !view.isPaused, "Resize must discard the old-size layer transform")
            scene.playAnimation(for: .idle)
            await settle()
            checkIdle()
            scene.loadSpritePack(from: nil)
            precondition(!view.isPaused && view.layer!.animation(forKey: key) == nil, "Pack changes must draw the new texture")
            scene.playAnimation(for: .idle)
            await settle()
            checkIdle()
            let idleLayer = view.layer!
            view.presentScene(nil)
            precondition(idleLayer.animation(forKey: key) == nil && idleLayer.magnificationFilter == .linear,
                         "Detaching must remove compositor animations and restore the original filter")
            view.presentScene(scene)
            scene.playAnimation(for: .idle)
            await settle()
            checkIdle()

            var states = manifest.states
            states["idle"] = .init(frames: ["pet_idle_0", "pet_sleep_0"], frameInterval: 0.2, loop: true)
            let multiple = PetScene(size: view.bounds.size, manifest: SpriteManifest(name: "Fixture", version: "1", states: states))
            view.presentScene(multiple)
            multiple.playAnimation(for: .idle)
            await settle()
            precondition(!view.isPaused && view.preferredFramesPerSecond == 60 && view.layer!.animation(forKey: key) == nil,
                         "Multi-frame idle keeps its original SpriteKit animation")
            let unattached = PetScene(size: frame.size, manifest: manifest)
            unattached.playAnimation(for: .idle)
            precondition(unattached.petNode.action(forKey: "RenderEngine.PetEffect") != nil, "Unattached previews retain the existing fallback")
            multiple.setRenderingVisible(false)
            panel.orderOut(nil)
            print("PASS: real SpriteKit/Core Animation breathing, live idle refresh, proportions, cross-display drawable scale, interrupted squash, cadence, redraw, facing, rotation, wake/actions, resize, pack, visibility, detach and multi-frame fallback; no production data read")
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        app.run()
    }
}
