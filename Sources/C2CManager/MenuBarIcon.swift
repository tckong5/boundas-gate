import AppKit

@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        guard let url = Bundle.main.url(forResource: "MenuBarArtwork", withExtension: "png"),
              let image = makeImage(from: url) else {
            return NSImage(size: NSSize(width: 20, height: 20))
        }
        return image
    }()

    static func makeImage(from url: URL) -> NSImage? {
        guard let artwork = NSImage(contentsOf: url),
              let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil),
              // The supplied artwork has two variants; show the left one.
              let selected = source.cropping(to: CGRect(x: 200, y: 65, width: 650, height: 650)) else {
            return nil
        }
        let image = NSImage(cgImage: selected, size: NSSize(width: 20, height: 20))
        image.isTemplate = false
        image.accessibilityDescription = "Boundas Gate"
        return image
    }
}
