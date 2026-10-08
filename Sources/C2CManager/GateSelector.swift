import AppKit
import CoreText
import SwiftUI

struct GateSelector: View {
    @Binding var isMainGate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turns: Double

    init(isMainGate: Binding<Bool>) {
        _isMainGate = isMainGate
        _turns = State(initialValue: isMainGate.wrappedValue ? 0 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GateOrbit(turns: turns, isMainGate: $isMainGate)
                .frame(height: 24)
                .padding(.horizontal, 14).padding(.top, 12)
            GateTagline(isMainGate: isMainGate)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.top, 7).padding(.bottom, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isMainGate ? "The Gate for Many." : "For Those Who Walk Alone.")
        }
        .onChange(of: isMainGate) { _, _ in
            withAnimation(reduceMotion ? nil : .timingCurve(0.42, 0, 0.30, 1, duration: 0.8)) {
                turns += 1
            }
        }
    }
}

private struct GateOrbit: View, Animatable {
    var turns: Double
    @Binding var isMainGate: Bool

    var animatableData: Double {
        get { turns }
        set { turns = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let radius = max(0, (geometry.size.width - 108) / 2)
            let angle = turns * .pi
            let mainDepth = -sin(angle)
            ZStack {
                orbitLabel("Main Gate", main: true, x: -radius * cos(angle), depth: mainDepth,
                           radius: radius, size: geometry.size)
                orbitLabel("Side Gates", main: false, x: radius * cos(angle), depth: -mainDepth,
                           radius: radius, size: geometry.size)
                GatePivot(turns: turns, switchGate: { isMainGate.toggle() })
                    .opacity(1 - 0.55 * abs(sin(angle)))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .zIndex(0)
            }
        }
    }

    private func orbitLabel(_ title: String, main: Bool, x: Double, depth: Double,
                            radius: Double, size: CGSize) -> some View {
        let active = radius > 0 ? (1 - x / radius) / 2 : 0.5
        let scale = 0.86 + 0.14 * active + 0.17 * max(0, depth) + 0.20 * min(0, depth)
        let opacity = min(1, 0.64 + 0.36 * active + 0.10 * max(0, depth) + 0.30 * min(0, depth))
        let weight = min(1, max(0, active + 0.22 * max(0, depth) + 0.20 * min(0, depth)))
        return GateOrbitLabel(title: title, activeWeight: weight, inactive: main != isMainGate) {
            if main != isMainGate { isMainGate = main }
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .position(x: size.width / 2 + x, y: size.height / 2 - depth * 6)
        .zIndex(depth)
    }
}

private struct GateOrbitLabel: View {
    let title: String
    let activeWeight: Double
    let inactive: Bool
    let switchGate: () -> Void
    @State private var hovering = false

    var body: some View {
        let weight = NSFont.Weight(rawValue: NSFont.Weight.regular.rawValue
                                   + (NSFont.Weight.bold.rawValue - NSFont.Weight.regular.rawValue) * activeWeight)
        Button(action: switchGate) {
            Text(title).font(Font(NSFont.systemFont(ofSize: 16, weight: weight)))
                .fixedSize()
                .foregroundStyle(hovering && inactive ? Color.accentColor : Color.primary)
                .scaleEffect(hovering && inactive ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .accessibilityValue(inactive ? "切換 Gate" : "目前 Gate")
    }
}

private struct GatePivot: View {
    let turns: Double
    let switchGate: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: switchGate) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                .scaleEffect((1 + 0.08 * abs(sin(turns * .pi))) * (hovering ? 1.06 : 1))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .accessibilityLabel("切換 Main Gate／Side Gates")
    }
}

private struct GateTagline: View {
    let isMainGate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedMain: Bool
    @State private var transition: TaglineTransition?

    init(isMainGate: Bool) {
        self.isMainGate = isMainGate
        _displayedMain = State(initialValue: isMainGate)
    }

    var body: some View {
        // Only the tagline has its own frame clock, paused at rest. Gate titles
        // finish first; navigation is never delayed by the presentation phases.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: transition == nil)) { timeline in
            let frame = transition?.frame(at: timeline.date)
                ?? TaglineFrame(main: displayedMain, body: 1, forming: false, dust: 0)
            ZStack {
                // Keep the same baseline and intrinsic height through the gap.
                tagline(GateGlyphField.main.text).hidden().accessibilityHidden(true)
                if let main = frame.main {
                    let field = main ? GateGlyphField.main : GateGlyphField.side
                    if let destruction = frame.destruction {
                        let texture = main ? GateDissolveField.main : GateDissolveField.side
                        tagline(field.text)
                            // Preserve partial materialization when interrupted;
                            // this mask stays fixed while the front eats the text.
                            .mask(GateGrainMask(field: field, erosion: 1 - destruction.initialGrain))
                            .mask(GateDestructionMask(width: texture.width, progress: destruction.progress))
                            .overlay {
                                Canvas { context, _ in
                                    destruction.draw(texture, grain: field, context: &context)
                                }
                                .allowsHitTesting(false).accessibilityHidden(true)
                            }
                    } else {
                        tagline(field.text)
                            .mask(GateGrainMask(field: field, erosion: 1 - frame.body))
                            .blur(radius: (1 - frame.body) * (frame.forming ? 0.8 : 0.2))
                            .overlay {
                                if frame.dust > 0.001 {
                                    Canvas { context, _ in
                                        dust(field, frame: frame, context: &context)
                                    }
                                    .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .transaction { $0.animation = nil }
        .onChange(of: isMainGate) { _, target in
            guard !reduceMotion else { settle(target); return }
            let now = Date()
            let current = transition?.frame(at: now)
                ?? TaglineFrame(main: displayedMain, body: 1, forming: false, dust: 0)
            // Rapid switches dissolve only the currently visible fragments,
            // then form the latest target. Never resurrect a complete old line.
            transition = TaglineTransition(outgoing: current.main, initialBody: current.body,
                                           incoming: target, startedAt: now, hold: transition == nil ? 0.2 : 0,
                                           priorDestruction: current.destruction)
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { settle(isMainGate) }
        }
        .task(id: transition?.id) {
            guard let pending = transition else { return }
            do {
                let remaining = max(0, pending.duration - Date().timeIntervalSince(pending.startedAt))
                try await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, transition?.id == pending.id else { return }
                settle(pending.incoming)
            } catch { /* A newer switch owns the remaining presentation. */ }
        }
    }

    private func settle(_ main: Bool) {
        displayedMain = main
        transition = nil
    }

    private func tagline(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).italic().foregroundStyle(.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    private func dust(_ field: GateGlyphField, frame: TaglineFrame, context: inout GraphicsContext) {
        let visibility = frame.dust * (frame.forming ? 0.32 : 0.38)
        for (index, point) in field.particles.enumerated() {
            let seed = gateNoise(index, 31)
            // Subpixel local wandering, with no radial or directional burst.
            let drift = frame.forming ? 1 - frame.body : frame.dust
            let center = CGPoint(x: point.x + sin(seed * 11 + frame.body * 2) * drift * 0.9,
                                 y: point.y + cos(seed * 17 + frame.body * 2) * drift * 0.45)
            let radius = 0.2 + gateNoise(index, 79) * 0.18
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(.secondary.opacity(visibility)))
        }
    }
}

private struct TaglineFrame {
    let main: Bool?
    let body: Double
    let forming: Bool
    let dust: Double
    var destruction: GateDestructionFrame? = nil
}

private struct TaglineTransition {
    let id = UUID()
    let outgoing: Bool?
    let initialBody: Double
    let incoming: Bool
    let startedAt: Date
    let hold: Double
    let priorDestruction: GateDestructionFrame?
    private var dissolve: Double { outgoing == nil ? 0 : 1.5 }
    private let gap = 0.12
    private let materialize = 0.98
    var duration: Double { hold + dissolve + gap + materialize }

    func frame(at date: Date) -> TaglineFrame {
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let emptyAt = hold + dissolve
        let formAt = emptyAt + gap
        if elapsed < emptyAt, let outgoing {
            let erosion = gateSmooth(hold, emptyAt, elapsed)
            return TaglineFrame(main: outgoing, body: initialBody * (1 - erosion), forming: false,
                                dust: 0,
                                destruction: GateDestructionFrame(elapsed: max(0, elapsed - hold),
                                                                  duration: dissolve,
                                                                  startProgress: priorDestruction?.progress ?? 0,
                                                                  initialGrain: priorDestruction?.initialGrain ?? initialBody))
        }
        // No text or particles from either line exist during this interval.
        if elapsed < formAt { return TaglineFrame(main: nil, body: 0, forming: false, dust: 0) }
        let formation = gateSmooth(formAt, duration, elapsed)
        return TaglineFrame(main: incoming, body: formation, forming: true,
                            dust: pow(max(0, sin(formation * .pi)), 1.2))
    }
}

// One shared birth threshold drives both the text cutout and each dust seed.
// The front sweeps right to left; the ash travels right into the emptied area.
private func gateDestructionThreshold(x: Double, y: Double, width: Double) -> Double {
    let cell = GateDissolveField.cell
    let column = Int(floor(x / cell)), row = Int(floor(y / cell))
    let centerX = (Double(column) + 0.5) * cell
    let centerY = (Double(row) + 0.5) * cell
    let turbulence = sin(centerY * 0.57 + centerX * 0.09) * 2.8
        + sin(centerY * 1.31 + centerX * 0.27) * 1.4
        + (gateNoise(column, row) - 0.5) * 4.2
    return min(0.80, max(0.04, 0.06 + 0.70 * (1 - (centerX + turbulence) / max(1, width))))
}

private struct GateDestructionMask: View {
    let width: Double
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let cell = GateDissolveField.cell
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var destroyed = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(min(width + 2, size.width) / cell)) {
                    let x = Double(column) * cell, y = Double(row) * cell
                    // Solid ahead of the boundary, empty behind it. No global fade.
                    guard progress >= gateDestructionThreshold(x: x, y: y, width: width) else { continue }
                    destroyed.addRect(CGRect(x: x, y: y, width: cell + 0.03, height: cell + 0.03))
                }
            }
            context.blendMode = .destinationOut
            context.fill(destroyed, with: .color(.white))
        }
    }
}

private struct GateDestructionFrame {
    let elapsed: Double
    let duration: Double
    let startProgress: Double
    let initialGrain: Double
    var progress: Double { startProgress + (1 - startProgress) * min(1, elapsed / duration) }

    func draw(_ field: GateDissolveField, grain: GateGlyphField, context: inout GraphicsContext) {
        // Stretch the front and its dust motion together, preserving the trail.
        let timeScale = 0.75 / duration
        for (index, seed) in field.seeds.enumerated() {
            let birth = gateDestructionThreshold(x: seed.point.x, y: seed.point.y, width: field.width)
            // Already destroyed pixels never emit again after a rapid switch.
            guard birth > startProgress else { continue }
            let bornAt = (birth - startProgress) / (1 - startProgress) * duration
            let age = (elapsed - bornAt) * timeScale
            let life = min(0.12 + gateNoise(index, 83) * 0.13, (duration - bornAt) * timeScale)
            guard age >= 0, age < life else { continue }
            let column = Int(seed.point.x / GateGlyphField.cell), row = Int(seed.point.y / GateGlyphField.cell)
            let threshold = grain.edges.contains(row * 4096 + column)
                ? 0.08 + gateNoise(column, row) * 0.46 : 0.25 + gateNoise(column, row) * 0.68
            let grainAlpha = 1 - gateSmooth(threshold - 0.045, threshold + 0.045, 1 - initialGrain)
            guard grainAlpha > 0.001 else { continue }
            let random = gateNoise(index, 113)
            let velocity = 65 + random * 85
            let drift = (gateNoise(index, 149) - 0.5) * 26
            let turbulence = sin(age * 26 + random * 6) - sin(random * 6)
            let center = CGPoint(x: seed.point.x + velocity * age + 30 * age * age,
                                 y: seed.point.y + drift * age + turbulence * min(1, age * 10) * 1.4)
            let opacity = seed.alpha * grainAlpha * 0.78 * (1 - gateSmooth(life * 0.45, life, age))
            let radius = 0.19 + gateNoise(index, 179) * 0.17
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2)),
                         with: .color(.secondary.opacity(opacity)))
        }
    }
}

// Cache the actual SwiftUI tagline raster once per sentence. Dense opaque-pixel
// samples supply real glyph-shaped ash, rather than dots placed around a label.
@MainActor
private struct GateDissolveField {
    nonisolated static let cell = 0.65
    static let main = GateDissolveField("The Gate for Many.")
    static let side = GateDissolveField("For Those Who Walk Alone.")
    struct Seed {
        let point: CGPoint
        let alpha: Double
    }
    let width: Double
    let seeds: [Seed]

    init(_ text: String) {
        let renderer = ImageRenderer(content: Text(text).font(.system(size: 11)).italic()
            .foregroundStyle(.black).lineLimit(1).fixedSize())
        renderer.scale = 2
        guard let image = renderer.cgImage else { width = 1; seeds = []; return }
        width = Double(image.width) / 2
        let height = Double(image.height) / 2
        guard let bitmap = CGContext(data: nil, width: image.width, height: image.height,
                                     bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = bitmap.data else { seeds = []; return }
        bitmap.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Store in the same top-down coordinate system used by SwiftUI Canvas.
        bitmap.translateBy(x: 0, y: Double(image.height))
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var points: [Seed] = []
        for row in 0..<Int(ceil(height / Self.cell)) {
            for column in 0..<Int(ceil(width / Self.cell)) {
                let x = (Double(column) + 0.5) * Self.cell, y = (Double(row) + 0.5) * Self.cell
                let px = Int(x * 2), py = Int(y * 2)
                guard px < image.width, py < image.height else { continue }
                let alpha = Double(pixels[(py * image.width + px) * 4 + 3]) / 255
                if alpha > 0.15 { points.append(Seed(point: CGPoint(x: x, y: y), alpha: alpha)) }
            }
        }
        seeds = points
    }
}

private struct GateGrainMask: View {
    let field: GateGlyphField
    let erosion: Double

    var body: some View {
        Canvas { context, size in
            let cell = GateGlyphField.cell
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) {
                    let noise = gateNoise(column, row)
                    // Glyph-edge grains disappear first; interiors break up later.
                    let threshold = field.edges.contains(row * 4096 + column) ? 0.08 + noise * 0.46 : 0.25 + noise * 0.68
                    let opacity = 1 - gateSmooth(threshold - 0.045, threshold + 0.045, erosion)
                    guard opacity > 0.001 else { continue }
                    context.fill(Path(CGRect(x: Double(column) * cell, y: Double(row) * cell,
                                             width: cell + 0.1, height: cell + 0.1)),
                                 with: .color(.white.opacity(opacity)))
                }
            }
        }
    }
}

// Two tiny, cached glyph fields guide the grain mask and particle origins.
// No running particle simulation, offscreen snapshots or idle frame updates.
private struct GateGlyphField {
    static let cell = 1.5
    static let main = GateGlyphField("The Gate for Many.")
    static let side = GateGlyphField("For Those Who Walk Alone.")
    let text: String
    let edges: Set<Int>
    let particles: [CGPoint]

    init(_ text: String) {
        self.text = text
        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]) as CFAttributedString)
        let width = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))) + 2
        let height = 18, scale = 2
        guard let bitmap = CGContext(data: nil, width: width * scale, height: height * scale,
                                     bitsPerComponent: 8, bytesPerRow: width * scale * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = bitmap.data else {
            edges = []; particles = []; return
        }
        bitmap.scaleBy(x: 2, y: 2)
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.textPosition = CGPoint(x: 0, y: 6)
        CTLineDraw(line, bitmap)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        func occupied(_ x: Double, _ y: Double) -> Bool {
            let px = Int(x * 2), py = Int((Double(height) - y) * 2)
            guard px >= 0, px < width * scale, py >= 0, py < height * scale else { return false }
            return pixels[(py * width * scale + px) * 4 + 3] > 40
        }
        var boundary: Set<Int> = [], points: [CGPoint] = []
        for row in 0..<Int(Double(height) / Self.cell) {
            for column in 0..<Int(Double(width) / Self.cell) {
                let x = (Double(column) + 0.5) * Self.cell, y = (Double(row) + 0.5) * Self.cell
                guard occupied(x, y) else { continue }
                if !occupied(x - Self.cell, y) || !occupied(x + Self.cell, y)
                    || !occupied(x, y - Self.cell) || !occupied(x, y + Self.cell) {
                    boundary.insert(row * 4096 + column)
                }
                if points.count < 120, gateNoise(column, row + 67) > 0.6 { points.append(CGPoint(x: x, y: y)) }
            }
        }
        edges = boundary; particles = points
    }
}

private func gateSmooth(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
    let t = min(1, max(0, (value - lower) / (upper - lower)))
    return t * t * (3 - 2 * t)
}

private func gateNoise(_ x: Int, _ y: Int) -> Double {
    let value = sin(Double(x) * 127.1 + Double(y) * 311.7 + 19.7) * 43758.5453
    return value - floor(value)
}
