import SwiftUI

struct HostingSurfaceRevision {
    private(set) var value: UInt64 = 0

    mutating func advance() {
        value &+= 1
    }
}

struct VersionedHostingRoot<Content: View>: View {
    let revision: UInt64
    let content: Content

    var body: some View {
        content.id(revision)
    }
}

@MainActor
final class ReusableHostingSurface<Content, Surface: AnyObject> {
    private let factory: @MainActor (Content) -> Surface
    private let update: @MainActor (Surface, Content) -> Void
    private var surface: Surface?
    private var needsUpdate = false

    init(
        factory: @escaping @MainActor (Content) -> Surface,
        update: @escaping @MainActor (Surface, Content) -> Void
    ) {
        self.factory = factory
        self.update = update
    }

    func invalidate() {
        needsUpdate = true
    }

    func resolve(_ makeContent: () -> Content) -> Surface {
        if let surface {
            guard needsUpdate else {
                return surface
            }

            needsUpdate = false
            update(surface, makeContent())
            return surface
        }

        needsUpdate = false
        let surface = factory(makeContent())
        self.surface = surface
        return surface
    }
}
