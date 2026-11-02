import AppKit
import SwiftUI
import UsageMonitor

/// Small vector marks adapted from CodeNotch; see THIRD_PARTY_NOTICES.md.
@MainActor
struct UsageProviderGlyph: View {
    let provider: UsageProviderID

    private static let images: [UsageProviderID: NSImage] = {
        let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("VitaPet_ChatUI.bundle")
        let bundle: Bundle?
        if let bundledURL, let installedBundle = Bundle(url: bundledURL) {
            bundle = installedBundle
        } else {
            #if SWIFT_PACKAGE
            bundle = Bundle.module
            #else
            // Standalone fixture executables carry the same resource bundle beside the binary.
            bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("VitaPet_ChatUI.bundle"))
            #endif
        }
        return Dictionary(uniqueKeysWithValues: UsageProviderID.allCases.compactMap { provider in
            guard let url = bundle?.url(forResource: provider.rawValue, withExtension: "pdf", subdirectory: "UsageGlyphs"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (provider, image)
        })
    }()

    var body: some View {
        if let image = Self.images[provider] {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
        } else {
            Image(systemName: UsagePresentation.symbol(provider)).resizable().scaledToFit()
        }
    }

    /// The vector PDFs keep a 4% export margin; undo it before applying the
    /// upstream ProviderGlyph optical scale so visible sizes match its paths.
    /// glm.pdf came from upstream's tight 24×24 zai.svg, so it takes the raw scale.
    static func scale(for provider: UsageProviderID) -> CGFloat {
        switch provider {
        case .codex: 1.08 * 0.94
        case .claude: 1.08 * 0.97
        case .glm: 1.0
        case .copilot: 1.08 * 0.96
        case .ollama: 1.08 * 0.95
        case .deepseek: 1
        }
    }
}
