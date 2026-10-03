import SwiftUI

struct ThinkingPillPlaygroundPresentation: Identifiable {
    let id = UUID()
    let title: LocalizedStringResource
    let tint: Color
}

struct ThinkingPillStatus {
    let title: LocalizedStringResource
    let tint: Color
}

/// Analytic drag momentum: independent of frame rate, and interruptible by a
/// new touch, Reset, or the scene becoming inactive.
struct GlassPillSpinMotion {
    static let sensitivity = 0.012
    static let friction = 3.2
    static let settlingDuration = 2.5
    static let returnDuration = 0.75
    var angle = CGSize.zero
    private(set) var velocity = CGSize.zero
    private(set) var releasedAt: TimeInterval?
    private(set) var returningAt: TimeInterval?

    func pose(at time: TimeInterval) -> CGSize {
        if let returningAt {
            let t = min(1, max(0, (time - returningAt) / Self.returnDuration))
            let remaining = 1 - t * t * (3 - 2 * t)
            return CGSize(width: angle.width * remaining, height: angle.height * remaining)
        }
        guard let releasedAt else { return angle }
        let elapsed = min(Self.settlingDuration, max(0, time - releasedAt))
        let distance = -expm1(-Self.friction * elapsed) / Self.friction
        return CGSize(width: angle.width + velocity.width * distance,
                      height: angle.height + velocity.height * distance)
    }

    mutating func stop(at time: TimeInterval) {
        angle = pose(at: time)
        velocity = .zero
        releasedAt = nil
        returningAt = nil
    }

    mutating func returnToFront(at time: TimeInterval, reduceMotion: Bool) {
        stop(at: time)
        if reduceMotion {
            angle = .zero
            return
        }
        // Choose the equivalent pose nearest the front, not a rewind of every
        // revolution the user made. A fresh drag can interrupt this return.
        angle = CGSize(width: angle.width.remainder(dividingBy: 2 * .pi),
                       height: angle.height.remainder(dividingBy: 2 * .pi))
        returningAt = time
    }

    mutating func release(pointsPerSecond: CGSize, at time: TimeInterval, reduceMotion: Bool) {
        stop(at: time)
        guard !reduceMotion else { return }
        velocity = CGSize(width: min(12, max(-12, pointsPerSecond.width * Self.sensitivity)),
                          height: min(12, max(-12, pointsPerSecond.height * Self.sensitivity)))
        releasedAt = abs(velocity.width) + abs(velocity.height) > 0.05 ? time : nil
    }
}

#if canImport(RealityKit) && canImport(UIKit)
import RealityKit
import UIKit
import Observation
import SceneKit

/// The 3D status surface hosted by ThinkingRow on supported platforms.
@available(iOS 18.0, *)
struct GlassThinkingPill: View {
    var title: LocalizedStringResource = "Thinking"
    var tint: Color = .cyan
    var reduceMotionOverride = false
    var isPaused = false
    var isInteractive = false
    var rotation = CGSize.zero
    var maximumDimension: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .subheadline) private var height = 46.0
    @State private var scene: GlassThinkingPillScene?
    @State private var interactiveReady = false

    private var reduceMotion: Bool { systemReduceMotion || reduceMotionOverride }
    private var aspectRatio: CGFloat { isInteractive ? 1 : 2.68 }
    private var renderHeight: CGFloat { maximumDimension ?? height }

    var body: some View {
        let input = renderInput
        Group {
            if isInteractive {
                GlassPillInteractiveSurface(input: input, onReady: { interactiveReady = true })
                    .background {
                        Color.clear
                            .opencodeGlassSurface(clear: true, tint: tint.opacity(0.18), in: GlassPillProjectedShape(rotation: rotation))
                    }
            } else {
                TimelineView(.animation(
                    minimumInterval: scene?.isAnimating == true ? 1.0 / 60 : 1.0 / 30,
                    paused: isPaused || reduceMotion || scenePhase != .active
                )) { timeline in
                    RealityView { content in
                        let scene = GlassThinkingPillScene()
                        content.camera = .virtual
                        content.add(scene.root)
                        let readiness = content.subscribe(to: SceneEvents.Update.self, on: nil, componentType: nil) { [weak scene] _ in
                            Task { @MainActor in scene?.didRenderFrame() }
                        }
                        scene.cancelReadinessObservation = { readiness.cancel() }
                        self.scene = scene
                        input.apply(to: scene)
                    } update: { _ in
                        if let scene {
                            input.apply(to: scene)
                            scene.advance(at: timeline.date)
                        }
                    } placeholder: {
                        GlassPillLoadingSurface(title: title, tint: tint, isInteractive: isInteractive)
                    }
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .overlay {
            if isInteractive ? !interactiveReady : scene?.isReady != true {
                GlassPillLoadingSurface(title: title, tint: tint, isInteractive: isInteractive)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: renderHeight * aspectRatio, maxHeight: renderHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(isInteractive && interactiveReady ? "glass-pill.playground.ready" : "glass-pill.renderer")
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scene?.finishImmediately() }
        }
        .onDisappear { scene?.finishImmediately() }
    }

    private var renderInput: GlassPillRenderInput {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return GlassPillRenderInput(
            title: String(localized: title),
            color: UIColor(tint).resolvedColor(with: traits),
            textColor: UIColor.label.resolvedColor(with: traits),
            darkAppearance: colorScheme == .dark,
            reduceMotion: isPaused || reduceMotion || scenePhase != .active,
            rotation: rotation,
            isInteractive: isInteractive
        )
    }
}

/// Project the actual capsule silhouette into the native glass surface, so
/// Liquid Glass samples the chat underneath even while the 3D toy turns.
private struct GlassPillProjectedShape: Shape {
    let rotation: CGSize

    private static let samples: [SIMD3<Float>] = [-0.96, 0.96].flatMap { center in
        (0...12).flatMap { latitude in
            (0..<32).map { longitude in
                let phi = Float(latitude) * .pi / 12
                let theta = Float(longitude) * 2 * .pi / 32
                return SIMD3<Float>(Float(center) + 0.44 * cos(phi),
                                    0.44 * sin(phi) * cos(theta), 0.44 * sin(phi) * sin(theta))
            }
        }
    }

    func path(in rect: CGRect) -> Path {
        let orientation = simd_quatf(angle: Float(rotation.height), axis: [1, 0, 0])
            * simd_quatf(angle: Float(rotation.width), axis: [0, 1, 0])
        let focal: CGFloat = rect.height / (2 * tan(CGFloat.pi / 15))
        var points: [CGPoint] = []
        for point in Self.samples {
            let rotated: SIMD3<Float> = orientation.act(point)
            let scale: CGFloat = focal / CGFloat(7.4 - rotated.z)
            let x: CGFloat = rect.midX + CGFloat(rotated.x) * scale
            let y: CGFloat = rect.midY - CGFloat(rotated.y) * scale
            points.append(CGPoint(x: x, y: y))
        }
        points.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func halfHull(_ points: [CGPoint]) -> [CGPoint] {
            var hull: [CGPoint] = []
            for point in points {
                while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], point) <= 0 {
                    hull.removeLast()
                }
                hull.append(point)
            }
            return hull
        }
        let outline = halfHull(points).dropLast() + halfHull(Array(points.reversed())).dropLast()
        return Path { path in
            path.addLines(Array(outline))
            path.closeSubpath()
        }
    }
}

/// The playground commits drag and reset poses in a single, nonanimated
/// transaction on its continuously rendered interactive surface.
@available(iOS 18.0, *)
private struct GlassPillInteractiveSurface: UIViewRepresentable {
    let input: GlassPillRenderInput
    let onReady: () -> Void

    final class Coordinator {
        let content = SCNScene()
        let toy = SCNNode()
        let sphere = SCNNode(geometry: SCNSphere(radius: 0.145))
        let text = SCNNode()
        let glass = SCNMaterial()
        let localLight = SCNNode()
        let halo = SCNNode(geometry: SCNPlane(width: 0.72, height: 0.72))
        var title = ""
        var pulses: Bool?

        init() {
            content.rootNode.addChildNode(toy)
            let shell = SCNBox(width: 2.8, height: 0.88, length: 0.88, chamferRadius: 0.44)
            shell.chamferSegmentCount = 48
            glass.lightingModel = .physicallyBased
            glass.diffuse.contents = UIColor(white: 0.08, alpha: 0.2)
            glass.metalness.contents = 0.15
            glass.roughness.contents = 0.08
            glass.transparency = 1
            glass.transparencyMode = .aOne
            glass.blendMode = .alpha
            glass.writesToDepthBuffer = false
            shell.materials = [glass]
            let shellNode = SCNNode(geometry: shell)
            shellNode.renderingOrder = 10
            toy.addChildNode(shellNode)
            sphere.position = SCNVector3(-0.9, 0, 0)
            sphere.renderingOrder = 20
            sphere.geometry?.materials = [SCNMaterial()]
            sphere.geometry?.firstMaterial?.lightingModel = .physicallyBased
            sphere.geometry?.firstMaterial?.roughness.contents = 0.16
            toy.addChildNode(sphere)
            // A camera-facing radial halo stays readable at every angle. Its
            // visible radius (0.36) fits entirely inside the capsule around the
            // centered sphere, so it needs no screen-space bloom outside glass.
            let glow = SCNMaterial()
            glow.lightingModel = .constant
            glow.diffuse.contents = GlassPillInteractiveSurface.haloTexture
            glow.blendMode = .add
            glow.transparencyMode = .aOne
            glow.writesToDepthBuffer = false
            glow.shaderModifiers = [.surface: """
                #pragma body
                float r = length(_surface.diffuseTexcoord * 2.0 - 1.0);
                float falloff = exp(-2.4 * r * r) * (1.0 - smoothstep(0.6, 1.0, r));
                _surface.diffuse.rgb *= falloff;
                _surface.diffuse.a *= falloff;
                """]
            halo.geometry?.materials = [glow]
            halo.position = sphere.position
            halo.renderingOrder = 15
            halo.constraints = [SCNBillboardConstraint()]
            toy.addChildNode(halo)
            localLight.light = SCNLight()
            localLight.light?.type = .omni
            localLight.light?.attenuationStartDistance = 0
            localLight.light?.attenuationEndDistance = 1.2
            localLight.position = sphere.position
            toy.addChildNode(localLight)
            toy.addChildNode(text)
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 24
            camera.position.z = 7.4
            content.rootNode.addChildNode(camera)
            for (position, intensity) in [(SCNVector3(-2, 3, 4), CGFloat(150)), (SCNVector3(3, -2, 2), CGFloat(80))] {
                let light = SCNNode()
                light.light = SCNLight()
                light.light?.type = .omni
                light.light?.intensity = intensity
                light.position = position
                content.rootNode.addChildNode(light)
            }
            content.lightingEnvironment.contents = GlassPillInteractiveSurface.studioLighting
        }

        func apply(_ input: GlassPillRenderInput) {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            toy.simdOrientation = simd_quatf(angle: Float(input.rotation.height), axis: [1, 0, 0])
                * simd_quatf(angle: Float(input.rotation.width), axis: [0, 1, 0])
            if title != input.title {
                title = input.title
                let mesh = SCNText(string: title, extrusionDepth: 0.12)
                mesh.font = .systemFont(ofSize: 0.32, weight: .medium)
                mesh.flatness = 0.005
                mesh.chamferRadius = 0.008
                text.geometry = mesh
                let face = SCNMaterial()
                face.lightingModel = .physicallyBased
                face.roughness.contents = 0.3
                face.metalness.contents = 0.25
                let edge = SCNMaterial()
                edge.lightingModel = .physicallyBased
                edge.roughness.contents = 0.22
                edge.metalness.contents = 0.45
                mesh.materials = [face, face, edge, edge, edge]
                text.renderingOrder = 20
                let (min, max) = text.boundingBox
                let scale = Swift.min(1, 1.8 / Swift.max(max.x - min.x, 0.001))
                text.scale = SCNVector3(scale, scale, scale)
                // Center the solid letters inside the capsule, including depth.
                text.position = SCNVector3(0.22 - (min.x + max.x) * scale / 2,
                                           -(min.y + max.y) * scale / 2, -(min.z + max.z) * scale / 2)
            }
            for material in text.geometry?.materials ?? [] {
                material.diffuse.contents = input.textColor
                material.emission.contents = input.textColor
                material.emission.intensity = 0.12
            }
            text.geometry?.firstMaterial?.diffuse.contents = input.textColor
            text.geometry?.firstMaterial?.shaderModifiers = input.reduceMotion ? nil : [
                .surface: """
                #pragma body
                float sweep = fract(u_time / 3.6) * 3.4 - 1.7;
                float shine = 1.0 - smoothstep(0.0, 0.28, abs(_surface.position.x - sweep));
                _surface.diffuse.rgb = mix(_surface.diffuse.rgb * 0.65, vec3(1.0), shine);
                _surface.emission.rgb = vec3(shine * 0.2);
                """
            ]
            sphere.geometry?.firstMaterial?.diffuse.contents = input.color
            glass.diffuse.contents = UIColor(white: 0.08, alpha: 0.2)
            // Emitted light must stay bright even when the neutral UI tint is
            // dark gray in light appearance. Keep hue, not text luminance.
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            input.color.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
            let emission = UIColor(hue: hue, saturation: saturation * 0.8, brightness: 1, alpha: 1)
            sphere.geometry?.firstMaterial?.emission.contents = emission
            localLight.light?.color = emission
            halo.geometry?.firstMaterial?.multiply.contents = emission
            text.opacity = 1
            SCNTransaction.commit()
            if pulses != !input.reduceMotion {
                pulses = !input.reduceMotion
                sphere.removeAllActions()
                localLight.removeAllActions()
                halo.removeAllActions()
                halo.opacity = 0.85
                sphere.scale = SCNVector3(1, 1, 1)
                sphere.geometry?.firstMaterial?.emission.intensity = 0.5
                localLight.light?.intensity = 100
                if !input.reduceMotion {
                    sphere.runAction(.repeatForever(.sequence([.scale(to: 1.16, duration: 1.2), .scale(to: 0.86, duration: 1.2)])))
                    sphere.runAction(.repeatForever(.customAction(duration: 2.4) { node, elapsed in
                        let phase = 0.5 - 0.5 * cos(Double(elapsed) * 2 * .pi / 2.4)
                        node.geometry?.firstMaterial?.emission.intensity = 0.12 + 1.2 * phase
                    }))
                    localLight.runAction(.repeatForever(.customAction(duration: 2.4) { node, elapsed in
                        let phase = 0.5 - 0.5 * cos(Double(elapsed) * 2 * .pi / 2.4)
                        node.light?.intensity = 40 + 180 * phase
                    }))
                    halo.opacity = 0.65
                    halo.runAction(.repeatForever(.sequence([.fadeOpacity(to: 1, duration: 1.2),
                                                           .fadeOpacity(to: 0.65, duration: 1.2)])))
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.content
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.isPlaying = true
        context.coordinator.apply(input)
        Task { @MainActor in
            onReady()
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.apply(input)
        view.rendersContinuously = !input.reduceMotion
        view.isPlaying = !input.reduceMotion
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        view.isPlaying = false
        view.scene = nil
    }

    private static let haloTexture: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { context in
        let colors = [0.95, 0.8, 0.35, 0.0].map { UIColor.white.withAlphaComponent($0).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                        locations: [0, 0.4, 0.7, 1]) else { return }
        context.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                                             endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
    }

    private static let studioLighting: [UIImage] = {
        (0..<6).map { face in
            UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
                UIColor(white: face == 2 ? 0.35 : 0.09, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                context.cgContext.setShadow(offset: .zero, blur: 12, color: UIColor.white.cgColor)
                UIColor(white: 1, alpha: 0.9).setFill()
                UIBezierPath(roundedRect: CGRect(x: face.isMultiple(of: 2) ? 24 : 84, y: 8, width: 12, height: 112), cornerRadius: 6).fill()
            }
        }
    }()
}

@available(iOS 18.0, *)
@MainActor
private struct GlassPillRenderInput {
    let title: String
    let color: UIColor
    let textColor: UIColor
    let darkAppearance: Bool
    let reduceMotion: Bool
    let rotation: CGSize
    let isInteractive: Bool

    func apply(to scene: GlassThinkingPillScene) {
        scene.set(title: title, color: color, textColor: textColor, darkAppearance: darkAppearance,
                  reduceMotion: reduceMotion, rotation: rotation, isInteractive: isInteractive)
    }
}

/// Owns only mesh/material and animation state, never session or tool state.
@available(iOS 18.0, *)
@MainActor
@Observable
private final class GlassThinkingPillScene {
    private static let shellWidth: Float = 2.8
    private static let shellRadius: Float = 0.44
    private static let sphereX: Float = -0.9
    private static let glowDiameter: Float = 1.2
    private(set) var isAnimating = false
    private(set) var isReady = false
    private(set) var renderedRotation = CGSize.zero
    @ObservationIgnored var cancelReadinessObservation: (() -> Void)?
    @ObservationIgnored private var renderedFrames = 0
    let root = Entity()
    private let toy = Entity()
    private let barrel = Entity()
    private let camera = PerspectiveCamera()
    private let shell: ModelEntity
    private let sphere: ModelEntity
    private let glow = ModelEntity()
    private let lettering = ModelEntity()
    private let colorLight = PointLight()
    private let keyLight = PointLight()
    private let fillLight = PointLight()
    @ObservationIgnored private var desiredTitle = ""
    @ObservationIgnored private var displayedTitle = ""
    @ObservationIgnored private var desiredColor = UIColor.cyan
    @ObservationIgnored private var currentColor = UIColor.cyan
    @ObservationIgnored private var textColor = UIColor.label
    @ObservationIgnored private var transition: Roll?
    @ObservationIgnored private var darkAppearance = false
    @ObservationIgnored private var pulses = true
    private let pulseStart = Date.now

    private struct Roll {
        let start: Date
        let title: String
        let fromColor: UIColor
        let toColor: UIColor
        let rotates: Bool
        var replaced = false
    }

    func didRenderFrame() {
        renderedFrames += 1
        guard renderedFrames >= 2 else { return }
        isReady = true
        cancelReadinessObservation?()
        cancelReadinessObservation = nil
    }

    init() {
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: UIColor(white: 0.16, alpha: 1))
        glass.roughness = 0.06
        glass.metallic = 0.35
        glass.clearcoat = 1.0
        glass.clearcoatRoughness = 0.04
        glass.blending = .transparent(opacity: .init(floatLiteral: 0.28))
        shell = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(Self.shellWidth, Self.shellRadius * 2, Self.shellRadius * 2),
                               cornerRadius: Self.shellRadius),
            materials: [glass]
        )
        sphere = ModelEntity(mesh: .generateSphere(radius: 0.145))

        root.addChild(toy)
        toy.addChild(barrel)
        barrel.addChild(shell)
        barrel.addChild(lettering)
        toy.addChild(sphere)
        sphere.position = [Self.sphereX, 0, 0]

        if let texture = Self.glowTexture {
            var halo = UnlitMaterial()
            halo.color = .init(tint: currentColor, texture: .init(texture))
            halo.blending = .transparent(opacity: .init(floatLiteral: 1))
            glow.model = ModelComponent(mesh: .generatePlane(width: Self.glowDiameter, height: Self.glowDiameter), materials: [halo])
            glow.position = [Self.sphereX, 0, 0.02]
            toy.addChild(glow)
        }

        // A real local light lets the sphere's hue spill across the curved shell.
        colorLight.position = [Self.sphereX, 0.32, 0.08]
        colorLight.light.intensity = 500
        colorLight.light.attenuationRadius = 3
        toy.addChild(colorLight)
        configureLight(keyLight, position: [-2, 5, 2], intensity: 1_200)
        configureLight(fillLight, position: [3, -2, 2], intensity: 650)

        camera.camera.fieldOfViewInDegrees = 24
        // Frame the visible glass at the leading edge rather than centering its
        // transparent render margins. This aligns it with the transcript text.
        camera.position = [0.22, 0, 3]
        root.addChild(camera)
        // RealityView does not expose rotation of its default environment. Pitch
        // the camera, pill, and local lights together against that unchanged map:
        // framing and rolls stay identical, but its bright strip clears the text.
        root.orientation = simd_quatf(angle: .pi / 6, axis: [1, 0, 0])
        applyColor(currentColor)
    }

    func set(title: String, color: UIColor, textColor: UIColor, darkAppearance: Bool, reduceMotion: Bool,
             rotation: CGSize, isInteractive: Bool) {
        camera.position = isInteractive ? [0, 0, 7.4] : [0.22, 0, 3]
        if renderedRotation != rotation {
            let orientation = simd_quatf(angle: Float(rotation.height), axis: [1, 0, 0])
                * simd_quatf(angle: Float(rotation.width), axis: [0, 1, 0])
            toy.orientation = orientation
        }
        renderedRotation = rotation
        let appearanceChanged = !self.textColor.isEqual(textColor)
        self.textColor = textColor
        self.darkAppearance = darkAppearance
        pulses = !reduceMotion
        desiredTitle = title
        desiredColor = color

        if displayedTitle.isEmpty || reduceMotion && (transition != nil || displayedTitle != title || appearanceChanged || !currentColor.isEqual(color)) {
            finishImmediately()
        } else {
            if appearanceChanged {
                replaceLettering(displayedTitle)
                applyColor(currentColor)
            }
            // Coalesce rapid tool updates into the next roll, without snapping mid-turn.
            beginIfNeeded()
        }
    }

    func finishImmediately() {
        transition = nil
        isAnimating = false
        barrel.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
        lettering.components.set(OpacityComponent(opacity: 1))
        replaceLettering(desiredTitle)
        applyColor(desiredColor)
        updateGlow(at: .now)
    }

    private func beginIfNeeded() {
        guard transition == nil else { return }
        guard displayedTitle != desiredTitle || !currentColor.isEqual(desiredColor) else {
            isAnimating = false
            return
        }
        transition = Roll(start: .now, title: desiredTitle, fromColor: currentColor,
                          toColor: desiredColor, rotates: displayedTitle != desiredTitle)
        isAnimating = true
    }

    // Advance inside RealityView's update pass so every frame reaches its renderer.
    // Idle breathing runs at 30 fps; turns use 60 fps, and Reduce Motion pauses both.
    func advance(at date: Date) {
        defer {
            updateGlow(at: date)
            updateTextShimmer(at: date)
            let facing = (toy.orientation * barrel.orientation).act(SIMD3<Float>(0, 0, 1)).z
            lettering.components.set(OpacityComponent(opacity: min(1, max(0, facing * 4))))
        }
        guard var roll = transition else { return }
        let progress = min(1, max(0, date.timeIntervalSince(roll.start) / (roll.rotates ? 0.95 : 0.4)))
        let eased = progress * progress * (3 - 2 * progress)
        let angle = Float(eased * 2 * Double.pi)
        if roll.rotates {
            barrel.orientation = simd_quatf(angle: -angle, axis: [1, 0, 0])
            // Hide the mirrored back of the lettering while the next word is loaded.
            lettering.components.set(OpacityComponent(opacity: min(1, max(0, cos(angle) * 4))))
            if progress >= 0.5, !roll.replaced {
                replaceLettering(roll.title)
                roll.replaced = true
            }
        }
        applyColor(Self.mix(roll.fromColor, roll.toColor, fraction: eased))
        transition = roll
        if progress >= 1 {
            barrel.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
            lettering.components.set(OpacityComponent(opacity: 1))
            applyColor(roll.toColor)
            transition = nil
            beginIfNeeded()
        }
    }

    private func replaceLettering(_ title: String) {
        displayedTitle = title
        let mesh = MeshResource.generateText(
            title, extrusionDepth: 0.003,
            font: .systemFont(ofSize: 0.32, weight: .medium),
            containerFrame: .zero, alignment: .left, lineBreakMode: .byClipping
        )
        Self.mapTextShimmerCoordinates(mesh)
        var ink = UnlitMaterial()
        ink.color = .init(tint: textColor)
        lettering.model = ModelComponent(mesh: mesh, materials: [ink])
        lettering.scale = .one
        lettering.position = .zero
        let bounds = lettering.visualBounds(relativeTo: lettering)
        let scale = min(1, 1.8 / max(bounds.extents.x, 0.001))
        lettering.scale = SIMD3<Float>(repeating: scale)
        lettering.position = [0.22 - bounds.center.x * scale, -bounds.center.y * scale, 0.365]
    }

    private func updateTextShimmer(at date: Date) {
        var ink = UnlitMaterial()
        if pulses, let texture = darkAppearance ? Self.darkTextShimmer : Self.lightTextShimmer {
            var sampler = MaterialParameters.Texture.Sampler()
            sampler.modify { $0.sAddressMode = .repeat }
            ink.color = .init(tint: .white, texture: .init(texture, sampler: sampler))
            ink.textureCoordinateTransform = .init(
                offset: [Float(-date.timeIntervalSince(pulseStart) / 3.6), 0], scale: [0.45, 1])
        } else {
            ink.color = .init(tint: textColor)
        }
        lettering.model?.materials = [ink]
    }

    // A single UV space across the shaped word lets the highlight travel across
    // letters, rather than restarting on each glyph or breaking localized text.
    private static func mapTextShimmerCoordinates(_ mesh: MeshResource) {
        let original = mesh.contents
        let bounds = mesh.bounds
        let width = max(bounds.max.x - bounds.min.x, 0.001)
        var mapped = MeshResource.Contents()
        for instance in original.instances {
            guard let model = original.models[instance.model] else { continue }
            let parts = model.parts.map { originalPart in
                var part = originalPart
                part.textureCoordinates = MeshBuffers.TextureCoordinates(part.positions.map { position in
                    let point = instance.transform * SIMD4<Float>(position.x, position.y, position.z, 1)
                    return SIMD2<Float>((point.x - bounds.min.x) / width, 0.5)
                })
                return part
            }
            mapped.models.insert(.init(id: instance.id, parts: parts))
            mapped.instances.insert(.init(id: instance.id, model: instance.id, at: instance.transform))
        }
        if !mapped.models.isEmpty { try? mesh.replace(with: mapped) }
    }

    private static let darkTextShimmer = makeTextShimmer(dark: true)
    private static let lightTextShimmer = makeTextShimmer(dark: false)

    private static func makeTextShimmer(dark: Bool) -> TextureResource? {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 4)).image { context in
            let base = UIColor(white: dark ? 0.58 : 0.12, alpha: 1).cgColor
            let highlight = UIColor(white: dark ? 1 : 0.7, alpha: 1).cgColor
            let colors = [base, base, highlight, base, base] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 0.37, 0.5, 0.63, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 512, y: 0), options: [])
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource.generate(from: cgImage, options: .init(semantic: .color))
    }

    private func applyColor(_ color: UIColor) {
        currentColor = color
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.16
        material.metallic = 0.25
        material.clearcoat = 1.0
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = darkAppearance ? 0.8 : 0.4
        sphere.model?.materials = [material]
        colorLight.light.color = color
        if var halo = glow.model?.materials.first as? UnlitMaterial {
            halo.color.tint = color
            glow.model?.materials = [halo]
        }
        // A restrained status tint keeps the glass mostly neutral.
        if var glass = shell.model?.materials.first as? PhysicallyBasedMaterial {
            glass.baseColor = .init(tint: Self.mix(UIColor(white: 0.16, alpha: 1), color, fraction: 0.32))
            shell.model?.materials = [glass]
        }
    }

    private func updateGlow(at date: Date) {
        let elapsed = date.timeIntervalSince(pulseStart)
        let phase = pulses ? Float(0.5 - 0.5 * cos(elapsed * 2 * .pi / 2.4)) : 0.5
        // Match the old pill's subtle whole-surface breath, anchored to its
        // leading edge without changing transcript layout or the text roll.
        let breathingScale: Float = pulses ? 0.994 + 0.02 * phase : 1
        toy.scale = SIMD3<Float>(repeating: breathingScale)
        toy.position.x = Self.shellWidth * (breathingScale - 1) / 2
        sphere.scale = SIMD3<Float>(repeating: pulses ? 0.86 + 0.30 * phase : 1)
        glow.components.set(OpacityComponent(opacity: darkAppearance ? 0.12 + 0.78 * phase : 0.08 + 0.42 * phase))
        colorLight.light.intensity = darkAppearance ? 200 + 1_400 * phase : 100 + 500 * phase
        if var material = sphere.model?.materials.first as? PhysicallyBasedMaterial {
            // Let the low point recover the sphere's shading; an always-white
            // emissive core otherwise hides the pulse through tone mapping.
            material.emissiveIntensity = darkAppearance ? 0.12 + 1.3 * phase : 0.08 + 0.62 * phase
            sphere.model?.materials = [material]
        }

        // Slow studio-light movement changes the real specular highlights on
        // the curved shell. Its softer rhythm is independent of the dot's pulse.
        let sweep = pulses ? Float(sin(elapsed * 2 * .pi / 5.6)) : 0
        let environmentPhase = pulses ? Float(0.5 - 0.5 * cos(elapsed * 2 * .pi / 3.8)) : 0.5
        keyLight.position = [2.7 * sweep, 5, 2]
        fillLight.position = [3, -1.8 + 0.35 * sweep, 2]
        keyLight.light.intensity = 1_050 + 300 * environmentPhase
        fillLight.light.intensity = 520 + 180 * (1 - environmentPhase)
    }

    // Mask the internal bloom to the capsule's cross-section. Keep its mesh at
    // a fixed scale so the brightness pulse never pushes light outside the glass.
    private static let glowTexture: TextureResource? = {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            let pixelsPerUnit = 128 / CGFloat(glowDiameter)
            let radius = CGFloat(shellRadius) - 0.02
            let capsule = CGRect(
                x: 64 + (-CGFloat(shellWidth) / 2 - CGFloat(sphereX) + 0.02) * pixelsPerUnit,
                y: 64 - radius * pixelsPerUnit,
                width: (CGFloat(shellWidth) - 0.04) * pixelsPerUnit,
                height: radius * 2 * pixelsPerUnit
            )
            UIBezierPath(roundedRect: capsule, cornerRadius: radius * pixelsPerUnit).addClip()
            let colors = [UIColor.white.withAlphaComponent(0.85).cgColor,
                          UIColor.white.withAlphaComponent(0.35).cgColor,
                          UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 0.3, 1]) else { return }
            context.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                                                 endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
        guard let image = image.cgImage else { return nil }
        return try? TextureResource.generate(from: image, options: .init(semantic: .color))
    }()

    private func configureLight(_ light: PointLight, position: SIMD3<Float>, intensity: Float) {
        light.position = position
        light.light.intensity = intensity
        light.light.attenuationRadius = 12
        root.addChild(light)
    }

    private static func mix(_ from: UIColor, _ to: UIColor, fraction: Double) -> UIColor {
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        from.getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        to.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        let t = CGFloat(fraction)
        return UIColor(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t,
                       blue: a.2 + (b.2 - a.2) * t, alpha: a.3 + (b.3 - a.3) * t)
    }
}

@available(iOS 18.0, *)
struct GlassThinkingPillPlayground: View {
    let title: LocalizedStringResource
    let tint: Color
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded = false
    @State private var motion = GlassPillSpinMotion()
    @State private var dragStart: CGSize?
    @State private var idleResetToken = 0

    var body: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.8 : 0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                let dimension = max(120, min(geometry.size.width - 32, geometry.size.height - 150, 640))
                VStack(spacing: 12) {
                    Spacer(minLength: 0)
                    TimelineView(.animation(minimumInterval: 1.0 / 60,
                                            paused: (motion.releasedAt == nil && motion.returningAt == nil) || scenePhase != .active)) { timeline in
                        let rotation = motion.pose(at: timeline.date.timeIntervalSinceReferenceDate)
                        GlassThinkingPill(
                            title: title, tint: tint, isInteractive: true,
                            rotation: rotation,
                            maximumDimension: dimension
                        )
                        .scaleEffect(expanded || reduceMotion ? 1 : 0.28)
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if dragStart == nil {
                                            motion.stop(at: Date.now.timeIntervalSinceReferenceDate)
                                            idleResetToken &+= 1
                                        }
                                        let start = dragStart ?? motion.angle
                                        dragStart = start
                                        motion.angle = CGSize(width: start.width + value.translation.width * GlassPillSpinMotion.sensitivity,
                                                              height: start.height + value.translation.height * GlassPillSpinMotion.sensitivity)
                                    }
                                    .onEnded { value in
                                        dragStart = nil
                                        motion.release(pointsPerSecond: value.velocity, at: Date.now.timeIntervalSinceReferenceDate,
                                                       reduceMotion: reduceMotion)
                                        idleResetToken &+= 1
                                    })
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Glass playground")
                                .accessibilityHint("Drag to spin the pill.")
                                .accessibilityValue(Text("\(Int(rotation.width * 180 / .pi))° horizontal, \(Int(rotation.height * 180 / .pi))° vertical"))
                                .accessibilityAdjustableAction { direction in
                                    motion.stop(at: Date.now.timeIntervalSinceReferenceDate)
                                    switch direction {
                                    case .increment: motion.angle.width += .pi / 4
                                    case .decrement: motion.angle.width -= .pi / 4
                                    @unknown default: break
                                    }
                                    idleResetToken &+= 1
                                }
                                .accessibilityIdentifier("glass-pill.playground.surface")
                        }
                    }
                    GlassPillPlaygroundCloseButton(onClose: onClose)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.keyboard)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("glass-pill.playground.overlay")
        .accessibilityAction(.escape) { onClose() }
        .task(id: motion.releasedAt) {
            guard motion.releasedAt != nil else { return }
            do { try await Task.sleep(for: .seconds(GlassPillSpinMotion.settlingDuration)) }
            catch { return }
            motion.stop(at: Date.now.timeIntervalSinceReferenceDate)
        }
        .task(id: idleResetToken) {
            guard dragStart == nil, scenePhase == .active else { return }
            do {
                try await Task.sleep(for: .seconds(3.5))
                guard motion.pose(at: Date.now.timeIntervalSinceReferenceDate) != .zero else { return }
                motion.returnToFront(at: Date.now.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                try await Task.sleep(for: .seconds(GlassPillSpinMotion.returnDuration))
                motion.stop(at: Date.now.timeIntervalSinceReferenceDate)
            } catch { }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { motion.stop(at: Date.now.timeIntervalSinceReferenceDate) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { motion.stop(at: Date.now.timeIntervalSinceReferenceDate) }
            idleResetToken &+= 1
        }
        .task {
            guard !expanded else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) { expanded = true }
        }
#if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["OPENCLIENT_GLASS_PLAYGROUND_AUTOPLAY"] == "1" else { return }
            do {
                try await Task.sleep(for: .seconds(8))
                motion.angle = CGSize(width: 1.2, height: 0.8)
                if ProcessInfo.processInfo.environment["OPENCLIENT_GLASS_PLAYGROUND_INERTIA"] == "1" {
                    motion.release(pointsPerSecond: CGSize(width: 450, height: -250),
                                   at: Date.now.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                }
                idleResetToken &+= 1
            } catch { }
        }
#endif
    }

}

private struct GlassPillLoadingSurface: View {
    let title: LocalizedStringResource
    let tint: Color
    let isInteractive: Bool

    var body: some View {
        HStack(spacing: isInteractive ? 20 : 8) {
            Circle().fill(tint).frame(width: isInteractive ? 24 : 8, height: isInteractive ? 24 : 8)
            Text(title).font(isInteractive ? .largeTitle : .subheadline)
        }
        .padding(isInteractive ? 24 : 10)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isInteractive ? .center : .leading)
    }
}

private struct GlassPillPlaygroundCloseButton: View {
    let onClose: () -> Void

    var body: some View {
        Button("Close", systemImage: "xmark", action: onClose)
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .opencodeGlassSurface(isInteractive: true, in: Circle())
            .accessibilityIdentifier("glass-pill.playground.close")
            .buttonStyle(.plain)
    }
}

@available(iOS 18.0, *)
private struct ThinkingPillOverlayModifier: ViewModifier {
    @Binding var presentation: ThinkingPillPlaygroundPresentation?
    let status: ThinkingPillStatus?
    let syncStore: DirectorySyncStore?
    let liveStatus: (() -> ThinkingPillStatus)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(presentation == nil)
            .accessibilityHidden(presentation != nil)
            .overlay {
                if let presentation {
                    Group {
                        if let syncStore, let liveStatus {
                            ThinkingPillLivePlayground(syncStore: syncStore, makeStatus: liveStatus, onClose: close)
                        } else {
                            GlassThinkingPillPlayground(title: status?.title ?? presentation.title,
                                                        tint: status?.tint ?? presentation.tint, onClose: close)
                        }
                    }
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { presentation = nil }
    }
}

@available(iOS 18.0, *)
private struct ThinkingPillLivePlayground: View {
    @ObservedObject var syncStore: DirectorySyncStore
    let makeStatus: () -> ThinkingPillStatus
    let onClose: () -> Void

    var body: some View {
        let status = makeStatus()
        GlassThinkingPillPlayground(title: status.title, tint: status.tint, onClose: onClose)
    }
}

extension View {
    @ViewBuilder
    func thinkingPillOverlay(_ presentation: Binding<ThinkingPillPlaygroundPresentation?>,
                             status: ThinkingPillStatus? = nil, syncStore: DirectorySyncStore? = nil,
                             liveStatus: (() -> ThinkingPillStatus)? = nil) -> some View {
        if #available(iOS 18.0, *) {
            modifier(ThinkingPillOverlayModifier(presentation: presentation, status: status,
                                                syncStore: syncStore, liveStatus: liveStatus))
        } else {
            self
        }
    }
}

#if DEBUG
@available(iOS 18.0, *)
struct GlassThinkingPillPreview: View {
    @State private var working = false
    @State private var playground: ThinkingPillPlaygroundPresentation?

    var body: some View {
        VStack(spacing: 36) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Thinking")
                    .font(.body)
                ThinkingRow(tint: working ? .orange : .secondary, title: working ? "Working" : "Thinking",
                            pausesPill: playground != nil,
                            onOpenPlayground: {
                    playground = ThinkingPillPlaygroundPresentation(title: working ? "Working" : "Thinking",
                                                                    tint: working ? .orange : .secondary)
                })
            }
            .frame(maxWidth: 260)
            Button(working ? "Thinking" : "Working") { working.toggle() }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("glass-pill.toggle")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OpenCodePlatformColor.groupedBackground)
        .thinkingPillOverlay($playground,
                             status: ThinkingPillStatus(title: working ? "Working" : "Thinking", tint: working ? .orange : .secondary))
        .task {
            if ProcessInfo.processInfo.environment["OPENCLIENT_GLASS_PLAYGROUND_AUTOPLAY"] == "1" {
                playground = ThinkingPillPlaygroundPresentation(title: "Thinking", tint: .secondary)
            }
            guard ProcessInfo.processInfo.environment["OPENCLIENT_GLASS_PILL_AUTOPLAY"] == "1" else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2.5)) }
                catch { return }
                working.toggle()
            }
        }
    }
}

#Preview("3D Glass Thinking Pill") {
    if #available(iOS 18.0, *) { GlassThinkingPillPreview() }
}
#endif
#endif
