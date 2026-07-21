import Foundation

enum RenderEngineResourceBundle {
    static let current: Bundle = {
        if let url = Bundle.main.url(
            forResource: "VitaPet_RenderEngine",
            withExtension: "bundle"
        ), let packagedBundle = Bundle(url: url) {
            return packagedBundle
        }
        return Bundle.module
    }()
}
