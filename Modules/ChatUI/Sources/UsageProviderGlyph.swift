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
}
