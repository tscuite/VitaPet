import Foundation

struct SpritePackPreviewRenderConfiguration: Equatable, Sendable {
    let normalizedPackPath: String?
    let previewSize: Double
    let reduceMotion: Bool

    init(packDirectory: URL?, previewSize: Double, reduceMotion: Bool = false) {
        normalizedPackPath = packDirectory?.standardizedFileURL.path
        self.previewSize = previewSize
        self.reduceMotion = reduceMotion
    }

    static func == (
        lhs: SpritePackPreviewRenderConfiguration,
        rhs: SpritePackPreviewRenderConfiguration
    ) -> Bool {
        lhs.normalizedPackPath == rhs.normalizedPackPath
            && lhs.reduceMotion == rhs.reduceMotion
            && (lhs.previewSize == rhs.previewSize
                || (lhs.previewSize.isNaN && rhs.previewSize.isNaN))
    }
}

struct SpritePackPreviewRenderPolicy: Sendable {
    private var renderedConfiguration: SpritePackPreviewRenderConfiguration?

    mutating func shouldRender(_ configuration: SpritePackPreviewRenderConfiguration) -> Bool {
        guard configuration != renderedConfiguration else {
            return false
        }

        renderedConfiguration = configuration
        return true
    }
}
