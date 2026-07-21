import AppKit
import RenderEngine
import SpriteKit
import SwiftUI

@MainActor
public struct SpritePackPreviewView: NSViewRepresentable {
    let packDirectory: URL?
    let previewSize: CGFloat

    public final class Coordinator {
        fileprivate var renderPolicy = SpritePackPreviewRenderPolicy()
    }

    public init(packDirectory: URL? = nil, previewSize: CGFloat = 64) {
        self.packDirectory = packDirectory
        self.previewSize = previewSize
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> SKView {
        let skView = SKView(frame: CGRect(x: 0, y: 0, width: previewSize, height: previewSize))
        skView.allowsTransparency = true
        skView.wantsLayer = true
        skView.layer?.backgroundColor = NSColor.clear.cgColor
        skView.layer?.cornerRadius = 8
        skView.layer?.masksToBounds = true
        renderIfNeeded(coordinator: context.coordinator) {
            renderScene(in: skView)
        }
        return skView
    }

    public func updateNSView(_ nsView: SKView, context: Context) {
        nsView.frame = CGRect(x: 0, y: 0, width: previewSize, height: previewSize)
        renderIfNeeded(coordinator: context.coordinator) {
            renderScene(in: nsView)
        }
    }

    func renderIfNeeded(coordinator: Coordinator, render: () -> Void) {
        let configuration = SpritePackPreviewRenderConfiguration(
            packDirectory: packDirectory,
            previewSize: Double(previewSize)
        )
        guard coordinator.renderPolicy.shouldRender(configuration) else {
            return
        }

        render()
    }

    private func renderScene(in skView: SKView) {
        let manifest = loadManifest()
        let sceneSize = CGSize(width: previewSize, height: previewSize)
        let petScene = PetScene(size: sceneSize, manifest: manifest)

        if let packDirectory {
            petScene.loadSpritePack(from: packDirectory)
        }

        petScene.playAnimation(for: previewAnimationState(for: manifest))
        skView.presentScene(petScene)
    }

    private func loadManifest() -> SpriteManifest {
        if let packDirectory,
           let manifest = try? SpritePackLoader.loadManifest(from: packDirectory) {
            return manifest
        }

        return SpritePackLoader.loadBundledManifest()
    }

    private func previewAnimationState(for manifest: SpriteManifest) -> RenderEngine.AnimationState {
        if let idleAnimation = manifest.states[RenderEngine.AnimationState.idle.rawValue],
           idleAnimation.loop {
            return .idle
        }

        for state in RenderEngine.AnimationState.allCases where state != .idle {
            if manifest.states[state.rawValue]?.loop == true {
                return state
            }
        }

        return .idle
    }
}
