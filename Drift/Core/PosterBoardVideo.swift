import AVFoundation
import Foundation
import UIKit
import VideoToolbox

/// How a video's frames are interpolated between keyframes
/// (`CAKeyframeAnimation.calculationMode`) — the reference's two options.
enum PosterBoardCalculationMode: String, CaseIterable, Identifiable {
    case linear
    case discrete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: String(localized: "Linear")
        case .discrete: String(localized: "Discrete")
        }
    }
}

/// A composition decode that failed before any frame was consumed. Only this
/// kind of failure may fall back to the slower per-frame generator; a failure
/// after frames have been written would duplicate them.
private struct CompositionUnavailable: Error {
    let message: String
}

/// A frame-reader failure with the system's error preserved in
/// full (domain + code): the `localizedDescription` alone is
/// usually the generic 「无法完成操作」, which says nothing about
/// what actually refused. Whether a generator fallback is still
/// safe is `decodeFrames`' call — it owns the consumed count.
private struct DecodeFailure: Error {
    let message: String

    init(_ error: Error?) {
        guard let error else {
            message = "读取器没有给出原因"
            return
        }
        let nsError = error as NSError
        message = "\(nsError.localizedDescription)（\(nsError.domain) 错误 \(nsError.code)）"
    }

    init(message: String) {
        self.message = message
    }
}

/// The screen a video document is built for. The video page's framing box,
/// the descriptor skeleton and the caml all use one of these, so the box the
/// user adjusts and the geometry written into the product cannot be measured
/// with two different rulers.
struct PosterBoardScreenMetrics: Sendable, Equatable {
    let width: Int
    let height: Int
    let scale: Int
    /// `iphone` or `ipad`; the descriptor's `logicalScreenClass` suffix.
    let idiom: String

    var logicalScreenClass: String {
        "\(width)w-\(height)h@\(scale)x~\(idiom)"
    }
}

/// How the user framed the video inside the screen-shaped box on
/// the video page (Grace, 2026-11-23): the box is the device screen,
/// the video moves and zooms behind it, and what is inside the box
/// is what the Lock Screen shows. Offsets are in document points
/// (the screen's own points), measured from the centred cover
/// position; `offsetY` is positive when the picture moves DOWN the
/// screen, the way the user's finger moved it.
struct PosterBoardFraming: Equatable {
    /// Multiplier over the cover scale: 1 fills the screen exactly,
    /// larger zooms in. Never below 1 — the picture must always
    /// cover the screen, with no empty edge inside the box.
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// The screen the box was measured against. Carried so a decode
    /// that happens after the device rotated still writes the box's
    /// ruler, not the current screen's. Older framings have nil and
    /// fall back to the decode-time screen.
    var document: PosterBoardScreenMetrics?

    var isDefault: Bool { scale == 1 && offsetX == 0 && offsetY == 0 }
}

/// A video wallpaper, as the page has assembled it.
struct PosterBoardVideoPlan {
    /// The picked video, copied into the app's container.
    var video: URL
    /// The freeze frame.  Required for the live-photo (non-looping) method —
    /// the reference raises rather than shipping a descriptor with no thumbnail.
    var thumbnail: URL?
    /// `loop_video`: CoreAnimation frame list (true) or a live photo (false).
    var loop = true
    var reverse = false
    /// `use_foreground`: promote the floating layer to the background, which
    /// hides the clock.
    var foreground = false
    var calculationMode: PosterBoardCalculationMode = .linear
    /// The video page's depth / motion switches (Grace, 2026-11-28):
    /// written into the loop descriptor's rendering configuration
    /// at decode. The live-photo shape carries no such file, so —
    /// like `reverse` and `foreground` — these only bite on the
    /// looping shape.
    var depthEffect = false
    var motionEffect = false
    /// The user's framing from the video page's box, or nil for the
    /// reference's centred cover. Only the caml loop has geometry of
    /// ours to write it into; the live-photo shape is laid out by
    /// the system and ignores it.
    var framing: PosterBoardFraming?

    var name: String { video.lastPathComponent }
}

/// `src/controllers/video_handler.py`, ported.
///
/// Two ways to put a video on the Lock Screen, and the reference implements both:
///
///   * **live photo** (`loop_video == false`) — the video goes into a Photos
///     poster descriptor, together with a freeze frame; iOS animates it on
///     raise.  The video rides inside a `.aar` archive whose layout
///     `src/controllers/aar/aar.py` builds by hand.
///   * **CoreAnimation loop** (`loop_video == true`) — the video is decoded to
///     JPEG frames and referenced by a `main.caml` keyframe animation, which
///     loops indefinitely.  This is the one with a hard cost: up to 400 frames
///     at the video's own resolution.
///
/// **What differs from the reference, and why:**
///
///   * Frames are decoded with `AVAssetReader` instead of OpenCV; OpenCV does
///     not exist on iOS, and this app is the device.  The stored orientation is
///     used, as OpenCV's does — a video carrying a rotation transform will
///     therefore render in its stored orientation, and that is logged rather
///     than silently "fixed" (changing it would change the caml's bounds away
///     from the JPEG dimensions, which is what the animation relies on).
///   * The video never goes through memory.  The reference reads the whole file
///     into `bytes` and hands it to `wrap_in_aar`; a phone video is not a
///     quantity to hold twice, so the `.aar` is written by streaming the file
///     behind its header.
enum PosterBoardVideo {
    /// The reference's `FRAME_LIMIT`, and the reason it exists: every frame is a
    /// JPEG the device decodes per animation step.
    static let frameLimit = 400

    /// The JPEG quality frames are stored at. The reference relies
    /// on OpenCV's `imwrite` default of 95; Grace ruled original
    /// quality with no reduction (2026-11-23), so frames are stored
    /// at the top of the scale, at the video's own resolution.
    static let jpegQuality: CGFloat = 1.0

    /// Both halves of `create_*_files`, into `outputDirectory`.
    ///
    /// Off the main thread on purpose. Decoding up to 400 frames and encoding
    /// each as a JPEG is minutes of work on a phone, and the compile step this
    /// belongs to is called from a `Task` a view's `body` started — i.e. from
    /// the main actor. Everything inside is synchronous once it is going, so the
    /// hop has to be made here rather than awaited around.
    /// Stage a selection's video into `outputDirectory`: decode it
    /// now, or — for a pre-decoded pick (video page, Grace,
    /// 2026-11-22) — copy the stored product across. The product of
    /// a decode is exactly the tree `generate(plan:)` writes, so the
    /// two are interchangeable downstream; the copy lands in the
    /// caller's scratch directory, never in the library, so the
    /// caller's cleanup can treat both the same way.
    static func generate(selection: PosterBoardSelection,
                         outputDirectory: URL,
                         log: @escaping @Sendable (String) -> Void) async throws {
        if let preGenerated = selection.preGeneratedVideoDirectory {
            let current = await MainActor.run {
                Self.screenMetrics(log: log)
            }
            // A small mismatch (an old 390-wide product on a 393-wide phone)
            // is harmless; the iPad case is a 3× document and must be rebuilt.
            // Compare the product's actual document, not just its class name,
            // so an update does not make every old decoded video unflashable.
            let storedSizes = Self.productDocumentSizes(at: preGenerated)
            if !storedSizes.isEmpty {
                let toleranceW = max(8, current.width / 10)
                let toleranceH = max(8, current.height / 10)
                for stored in storedSizes {
                    if abs(stored.width - current.width) > toleranceW
                        || abs(stored.height - current.height) > toleranceH {
                        throw DriftError("这个已解码的视频有一层是按 \(stored.width)×\(stored.height) 生成的，"
                            + "当前屏幕是 \(current.width)×\(current.height)；请重新解码后再刷，"
                            + "否则锁屏会把画面缩放裁切。")
                    }
                }
                if storedSizes.contains(where: {
                    $0.width != current.width || $0.height != current.height
                }) {
                    log("  → pre-decoded document differs slightly from the current "
                        + "\(current.width)×\(current.height); keeping it")
                }
            }
            log("  → video: staging the pre-decoded product of "
                + "\(selection.preGeneratedVideoName ?? "Video")")
            let fm = FileManager.default
            for child in try fm.contentsOfDirectory(at: preGenerated, includingPropertiesForKeys: nil) {
                try fm.copyItem(at: child,
                                to: outputDirectory.appendingPathComponent(child.lastPathComponent,
                                                                           isDirectory: true))
            }
            return
        }
        guard let plan = selection.plan else { return }
        try await generate(plan: plan, outputDirectory: outputDirectory, log: log)
    }

    static func generate(plan: PosterBoardVideoPlan,
                         outputDirectory: URL,
                         log: @escaping @Sendable (String) -> Void) async throws {
        // Capture the screen before leaving the main actor. The descriptor
        // skeleton and the caml document are built from the same metrics,
        // and a decode that starts after a rotation must not re-read a
        // different screen halfway through.
        let metrics = await MainActor.run { Self.screenMetrics(log: log) }
        try await Task.detached(priority: .utility) {
            if plan.loop {
                try await generateLoop(plan: plan, metrics: metrics,
                                       outputDirectory: outputDirectory, log: log)
            } else {
                try await generateLivePhoto(plan: plan, outputDirectory: outputDirectory, log: log)
            }
        }.value
    }

    // MARK: - CoreAnimation loop

    /// The phone-shaped class the bundled skeleton was authored at.
    private static let legacyScreenClass = "390w-844h@3x~iphone"

    /// Write the bundled loop skeleton with this device's screen class.
    ///
    /// The skeleton is a 390×844 iPhone tree: the wallpaper directory and
    /// the three `.ca` directories carry the class in their names, `Wallpaper.plist`
    /// and `userInfo` name the same files, and each `.ca`'s `index.xml` / `main.caml`
    /// declare 390×844. On an iPad the frames were correctly built at 1210×834
    /// points while the descriptor still claimed a 390×844 canvas, so the system
    /// scaled the landscape document into a portrait phone canvas. This rewrites
    /// every one of those size declarations from the same metrics the caml uses.
    private static func writeVideoLoopSkeleton(into root: URL,
                                               metrics: PosterBoardScreenMetrics,
                                               depthEffect: Bool,
                                               motionEffect: Bool) throws {
        let fm = FileManager.default
        let screenClass = metrics.logicalScreenClass
        for (relative, data) in PosterBoardResources.videoLoopDescriptor.sorted(by: { $0.key < $1.key }) {
            let newRelative = relative.replacingOccurrences(of: legacyScreenClass,
                                                            with: screenClass)
            var newData = data
            if relative.hasSuffix("/index.xml") {
                newData = try rewriteIndex(data, metrics: metrics)
            } else if relative.hasSuffix("/main.caml") {
                newData = try rewriteRootCAML(data, metrics: metrics)
            } else if relative == "versions/1/com.apple.posterkit.provider.instance.renderingConfiguration.plist" {
                // The bundled copy allows both system effects. The
                // page's switches decide instead (Grace, 2026-11-28):
                // an effect that is off is written as disabled, so
                // the system leaves the picture as decoded.
                newData = try PosterBoardConverter.renderingConfigurationData(
                    depthEffectDisabled: !depthEffect,
                    motionEffectsDisabled: !motionEffect)
            } else if relative.hasSuffix("Wallpaper.plist") || relative.hasSuffix("userInfo") {
                newData = try replaceScreenClass(in: data, with: screenClass)
            }
            let destination = URL(fileURLWithPath: root.path + "/" + newRelative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try newData.write(to: destination)
        }
    }

    private static func rewriteIndex(_ data: Data,
                                     metrics: PosterBoardScreenMetrics) throws -> Data {
        guard var text = String(data: data, encoding: .utf8) else {
            throw DriftError("视频描述符的 index.xml 读不出来。")
        }
        text = text.replacingOccurrences(of: "<real>390</real>",
                                         with: "<real>\(metrics.width)</real>")
        text = text.replacingOccurrences(of: "<real>844</real>",
                                         with: "<real>\(metrics.height)</real>")
        return Data(text.utf8)
    }

    private static func rewriteRootCAML(_ data: Data,
                                        metrics: PosterBoardScreenMetrics) throws -> Data {
        guard var text = String(data: data, encoding: .utf8) else {
            throw DriftError("视频描述符的 main.caml 读不出来。")
        }
        text = text.replacingOccurrences(of: "bounds=\"0 0 390 844\"",
                                         with: "bounds=\"0 0 \(metrics.width) \(metrics.height)\"")
        text = text.replacingOccurrences(of: "position=\"195 422\"",
                                         with: "position=\"\(Self.half(metrics.width)) \(Self.half(metrics.height))\"")
        return Data(text.utf8)
    }

    /// The centre in points, without turning an even 195 into 195.0 —
    /// the 390×844 regression compares the bundled skeleton byte for byte.
    private static func half(_ value: Int) -> String {
        value % 2 == 0 ? "\(value / 2)" : String(format: "%.1f", Double(value) / 2)
    }

    private static func replaceScreenClass(in data: Data, with screenClass: String) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DriftError("视频描述符的尺寸声明读不出来。")
        }
        return Data(text.replacingOccurrences(of: legacyScreenClass,
                                              with: screenClass).utf8)
    }

    /// The document sizes a stored loop product's layers were built for,
    /// read from every `.ca/index.xml`. Live-photo products have no such
    /// files and return an empty array. All layers are checked: an old iPad
    /// product can have the chosen layer at the device size while the two
    /// empty layers still declare 390×844.
    static func productDocumentSizes(at directory: URL) -> [(width: Int, height: Int)] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var sizes: [(width: Int, height: Int)] = []
        for case let url as URL in walker where url.lastPathComponent == "index.xml" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil),
                  let dict = plist as? [String: Any],
                  let width = dict["documentWidth"] as? NSNumber,
                  let height = dict["documentHeight"] as? NSNumber else {
                continue
            }
            sizes.append((Int(width.doubleValue.rounded()), Int(height.doubleValue.rounded())))
        }
        return sizes
    }

    /// Whether a stored product's documents disagree with the current
    /// screen beyond the flash gate's tolerance — the same comparison
    /// `generate` refuses on, exposed so the decoded-video list can
    /// mark such an item up front (Grace, 2026-11-28: a user tapped a
    /// stale same-name item three times and was refused three times
    /// before picking the re-decoded one). Live-photo products carry
    /// no documents and never mismatch.
    static func productMismatchesCurrentScreen(at directory: URL) async -> Bool {
        let current = await MainActor.run { Self.deviceScreenMetrics() }
        let toleranceW = max(8, current.width / 10)
        let toleranceH = max(8, current.height / 10)
        return productDocumentSizes(at: directory).contains {
            abs($0.width - current.width) > toleranceW
                || abs($0.height - current.height) > toleranceH
        }
    }

    /// `create_video_loop_files`.
    private static func generateLoop(plan: PosterBoardVideoPlan,
                                     metrics capturedMetrics: PosterBoardScreenMetrics,
                                     outputDirectory: URL,
                                     log: @escaping @Sendable (String) -> Void) async throws {
        // The framing box's ruler wins when it carries one: the user
        // adjusted against that screen, and a later rotation must not
        // silently move the document out from under those offsets.
        let metrics = plan.framing?.document ?? capturedMetrics
        let root = outputDirectory.appendingPathComponent("descriptor/VideoCAML", conformingTo: .data)
        try writeVideoLoopSkeleton(into: root, metrics: metrics,
                                   depthEffect: plan.depthEffect,
                                   motionEffect: plan.motionEffect)
        log("  → 渲染配置：景深 \(plan.depthEffect ? "开" : "关")、动态 \(plan.motionEffect ? "开" : "关")")

        // The reference's path is fixed: the descriptor skeleton's own wallpaper
        // directory, whose `.ca` is what gets replaced.
        let screenClass = metrics.logicalScreenClass
        let wallpaper = root.appendingPathComponent(
            "versions/1/contents/9183.Custom-\(screenClass).wallpaper", conformingTo: .data)
        let floating = wallpaper.appendingPathComponent(
            "9183.Custom_Floating-\(screenClass).ca", conformingTo: .data)
        let background = wallpaper.appendingPathComponent(
            "9183.Custom_Background-\(screenClass).ca", conformingTo: .data)

        let ca: URL
        if plan.foreground {
            // Retitle the floating layer to the background one: the wallpaper
            // then covers the clock.
            try? FileManager.default.removeItem(at: background)
            try FileManager.default.moveItem(at: floating, to: background)
            ca = background
        } else {
            ca = background
        }

        log("  → video loop: decoding \(plan.name) into \(ca.lastPathComponent)")
        try await writeCAML(video: plan.video,
                            caDirectory: ca,
                            metrics: metrics,
                            framing: plan.framing,
                            calculationMode: plan.calculationMode.rawValue,
                            reverse: plan.reverse,
                            log: log)
    }

    /// `create_caml`: decode every frame, then write the frame list around them.
    private static func writeCAML(video: URL,
                                  caDirectory: URL,
                                  metrics: PosterBoardScreenMetrics,
                                  framing: PosterBoardFraming?,
                                  calculationMode: String,
                                  reverse: Bool,
                                  log: @escaping @Sendable (String) -> Void) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DriftError("\(video.lastPathComponent) 没有视频轨道。")
        }
        // The frames are decoded and encoded in their **display** orientation:
        // the video page's framing box and lock-screen preview both apply
        // `preferredTransform`, so a rotated video must not reach the Lock
        // Screen sideways. A non-identity transform is applied by the reader
        // composition below; an identity one keeps the old track-output path.
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayRect = Self.displayRect(naturalSize: naturalSize, transform: transform)
        let width = max(1, Int(abs(displayRect.width).rounded()))
        let height = max(1, Int(abs(displayRect.height).rounded()))
        // A rotation transform usually carries a translation that puts the
        // rotated frame at a negative origin. The composition's canvas starts
        // at 0,0, so without normalising that origin the whole frame lands
        // outside the render size and the video is black.
        let displayTransform = transform.concatenating(
            CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY))
        guard width > 0, height > 0 else {
            throw DriftError("\(video.lastPathComponent) 报告了一个 "
                + "\(width)×\(height) 的帧——没有可解码的内容。")
        }
        if transform != .identity {
            log("  → \(video.lastPathComponent) carries a rotation transform; "
                + "frames are decoded in display orientation "
                + "(\(width)×\(height)) so the Lock Screen matches the preview.")
        }

        let fps = try await framesPerSecond(of: track)
        let assetDuration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(assetDuration)
        let estimate = max(1, Int((seconds * fps).rounded()))
        guard estimate <= frameLimit else {
            throw DriftError("\(video.lastPathComponent) 大约有 \(estimate) 帧；"
                + "CoreAnimation 壁纸的帧数上限是 \(frameLimit)。请修剪视频，或者"
                + "使用实况照片方式（关闭循环）。")
        }
        let duration = Double(estimate) / fps

        // The document is the logical screen, **not** the frame size. The
        // reference's `create_caml` grew these four parameters for exactly this
        // reason (743d363): PosterKit's depth effect parallaxes planes whose
        // bounds and origin differ from the document, and a document sized to the
        // video — with the layer dead-centre at scale 1.0 — gives it nothing to
        // travel against, which reads as a flat wallpaper on iOS 27.
        //
        // `cover` scales the frames to fill the document; the reference's own
        // default `bounds_scale` is 1.0 and its offsets are 0, so the defaults
        // reproduce it exactly, and a caller wanting travel passes more.
        let docWidth = metrics.width
        let docHeight = metrics.height
        let cover = max(Double(docWidth) / Double(width), Double(docHeight) / Double(height))
        // The user's framing rides on the centred cover: their zoom
        // multiplies it, their drag moves the layer's centre by the
        // offsets they left in the box. The caml measures the centre
        // from the BOTTOM of the document (the transform layer's
        // parent is unflipped), so a picture the user dragged down
        // the screen subtracts from the centre height here.
        let layerScale = cover * Self.depthScale * (framing?.scale ?? 1)
        let centerX = Double(docWidth) / 2 + (framing?.offsetX ?? 0)
        let centerY = Double(docHeight) / 2 - (framing?.offsetY ?? 0)
        if let framing, !framing.isDefault {
            log("  → user framing: scale ×\(String(format: "%.3f", framing.scale)) over cover, "
                + "offset (\(String(format: "%.1f", framing.offsetX)), "
                + "\(String(format: "%.1f", framing.offsetY))) points")
        }
        // The layer is published by name, and `index.xml` has to name the same
        // one — the reference passes the same `layer_name` to both writers.
        let layerName = "Chip"

        // Only the frames are cleared. The `.ca` directory itself comes from the
        // bundled descriptor and carries `index.xml`/`main.caml` — which are
        // rewritten below anyway, but nothing else in it is ours to delete.
        let assets = caDirectory.appendingPathComponent("assets", conformingTo: .data)
        try? FileManager.default.removeItem(at: assets)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        var caml = PosterBoardTemplates.camlHeader(width: width, height: height,
                                                   docWidth: docWidth, docHeight: docHeight,
                                                   centerX: centerX, centerY: centerY,
                                                   layerScale: layerScale, layerName: layerName,
                                                   calculationMode: calculationMode,
                                                   duration: duration,
                                                   reverse: reverse ? 1 : 0)
        var written = 0
        try await decodeFrames(asset: asset, track: track,
                               displaySize: (width: width, height: height),
                               transform: displayTransform,
                               fps: fps, duration: assetDuration, log: log) { frame in
            guard written < frameLimit else { return false }
            let jpeg = try Self.jpeg(frame)
            try jpeg.write(to: assets.appendingPathComponent("\(written).jpg"))
            caml += PosterBoardTemplates.camlFrame(index: written)
            written += 1
            return true
        }
        guard written > 0 else {
            throw DriftError("\(video.lastPathComponent) 没有解码出任何帧。")
        }
        caml += PosterBoardTemplates.camlFooter()
        try caml.write(to: caDirectory.appendingPathComponent("main.caml"),
                       atomically: true, encoding: .utf8)
        // The generated index declares `scalesToFitInPlayer` on, which
        // lets the player rescale the whole document to fit its view.
        // On iPad that fit comes out at the display's scale factor (the
        // field case measured ≈2.03× on a @2x iPad Air): the lock screen
        // shows the video zoomed well past the preview's cover, while
        // packs — whose index.xml declares no fit at all — and the
        // reference's own iPad video skeleton (fit off, pixel units)
        // display correctly. Turn the fit off for the video layer so
        // the document renders at its declared size; the template
        // itself stays untouched (it is generated from the reference),
        // so the deviation lives here where the reason is written down.
        let indexText = PosterBoardTemplates.camlIndex(
            docWidth: docWidth, docHeight: docHeight, layerName: layerName)
            .replacingOccurrences(of: "<key>scalesToFitInPlayer</key>\n\t<true/>",
                                  with: "<key>scalesToFitInPlayer</key>\n\t<false/>")
        try indexText.write(to: caDirectory.appendingPathComponent("index.xml"),
                            atomically: true, encoding: .utf8)
        log("  → index.xml: scalesToFitInPlayer off (iPad zoom fix attempt)")
        log("  → \(written) frame(s), \(width)×\(height) frames in a \(docWidth)×\(docHeight) "
            + "document, layer \(layerName) at scale \(String(format: "%.4f", layerScale)), "
            + "\(String(format: "%.2f", fps)) fps, "
            + "duration \(String(format: "%.3f", duration)) s")
    }

    /// The device screen in points, for the video page's framing
    /// box. Deliberately the same numbers the descriptor skeleton
    /// and caml write: the box the user adjusts and the geometry the
    /// decode writes are measured with one ruler, so the two cannot
    /// drift apart.
    static func deviceScreenPoints() -> (width: Int, height: Int) {
        let metrics = deviceScreenMetrics()
        return (metrics.width, metrics.height)
    }

    /// The same screen's scale, so the framing page can name the
    /// box in pixels (points × scale) the way the user knows their
    /// screen.
    static func deviceScreenScale() -> Double {
        Double(deviceScreenMetrics().scale)
    }

    /// The screen metrics every video document is built from.
    static func deviceScreenMetrics() -> PosterBoardScreenMetrics {
        screenMetrics { _ in }
    }

    /// The display size after a video's rotation transform. The caml
    /// frame bounds and the JPEGs both use this, so a rotated video
    /// does not reach the Lock Screen sideways.
    private static func displayRect(naturalSize: CGSize,
                                    transform: CGAffineTransform) -> CGRect {
        CGRect(origin: .zero, size: naturalSize).applying(transform)
    }

    /// The document size, in points: the device's own screen, which is the one
    /// number the background and foreground packages were built for.
    ///
    /// Read from a `UIScreen` reached through a window scene rather than
    /// `UIScreen.main` — deprecated in iOS 26, and this app targets 26. When
    /// no scene is reachable the device's own main screen is still a truer
    /// ruler than any assumed size (it is what the deep-repair canvas falls
    /// back to as well); the reference's own 390x844 default (a 6.1" iPhone)
    /// is only the last resort, for a moment when no screen at all can be
    /// seen. The fallbacks are logged, because they silently change the
    /// document every frame is laid out in.
    private static func screenMetrics(log: @escaping @Sendable (String) -> Void)
        -> PosterBoardScreenMetrics {
        guard let screen = activeScreen(), !screen.bounds.isEmpty else {
            if !UIScreen.main.bounds.isEmpty {
                let bounds = UIScreen.main.bounds
                let width = max(1, Int(bounds.width.rounded()))
                let height = max(1, Int(bounds.height.rounded()))
                let scale = max(1, Int(UIScreen.main.scale.rounded()))
                let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
                log("  ⚠️ no window scene is reachable; using the main screen's "
                    + "\(width)x\(height)@\(scale)x~\(idiom) document instead.")
                return PosterBoardScreenMetrics(width: width, height: height,
                                                scale: scale, idiom: idiom)
            }
            log("  ⚠️ no window scene is reachable; falling back to the reference's "
                + "390x844@3x~iphone document. The frames will be laid out for a screen "
                + "this device does not have.")
            return PosterBoardScreenMetrics(width: 390, height: 844, scale: 3, idiom: "iphone")
        }
        let bounds = screen.bounds
        let width = max(1, Int(bounds.width.rounded()))
        let height = max(1, Int(bounds.height.rounded()))
        let scale = max(1, Int(screen.scale.rounded()))
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        log("  → document \(width)×\(height) points @\(scale)x~\(idiom) "
            + "(the device screen; the reference assumes a 390x844 iPhone)")
        return PosterBoardScreenMetrics(width: width, height: height,
                                        scale: scale, idiom: idiom)
    }

    /// The display of the foreground scene — the one screen every
    /// size in this file is measured against. `.foregroundActive`
    /// first: a scene that is on screen but not active (say, a
    /// Slide Over companion) is not the one whose size a wallpaper
    /// document should match.
    private static func activeScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let ordered = scenes.sorted { lhs, rhs in
            let rank: (UIScene.ActivationState) -> Int = {
                switch $0 {
                case .foregroundActive: return 0
                case .foregroundInactive: return 1
                default: return 2
                }
            }
            return rank(lhs.activationState) < rank(rhs.activationState)
        }
        if let screen = ordered.first(where: { !$0.screen.bounds.isEmpty })?.screen {
            return screen
        }
        return scenes.first?.screen
    }

    /// `create_caml`'s `bounds_scale`, kept at the reference's default.
    ///
    /// 1.0 is `cover`: the frames exactly fill the document, centred. A value
    /// above 1 makes the animated layer larger than the document, which is what
    /// gives the depth pass travel to parallax against — the reference exposes it
    /// for that, and the Odyssey's `spartanbg` ships bounds 1852x4104 inside a
    /// 390x844 document. Nothing in this port drives it yet: the page has no
    /// control for it, and inventing a default that is not the reference's would
    /// change how every video wallpaper looks on a device that has never run
    /// one. It is a named constant so the value is one edit away, not a literal
    /// buried in the geometry.
    static let depthScale: Double = 1.0

    // MARK: - Live photo

    /// `create_live_photo_files`.
    private static func generateLivePhoto(plan: PosterBoardVideoPlan,
                                          outputDirectory: URL,
                                          log: @escaping @Sendable (String) -> Void) async throws {
        let root = outputDirectory.appendingPathComponent(
            "video-descriptor/\(PosterBoardResources.livePhotoIdentifier)", conformingTo: .data)
        try write(PosterBoardResources.livePhotoDescriptor, into: root)

        let contents = root.appendingPathComponent(
            "versions/0/contents/0EFB6A0F-7052-4D24-8859-AB22BADF2E93", conformingTo: .data)
        let layerStack = contents.appendingPathComponent("output.layerStack", conformingTo: .data)
        let segmentation = contents.appendingPathComponent("input.segmentation", conformingTo: .data)

        // The reference converts anything that is not already a .mov; a .mov is
        // used as it stands. Spelled as a statement rather than a ternary:
        // `try await` inside a conditional expression has to be marked on the
        // whole expression, and the branch is clearer as a branch.
        let converted: URL?
        if plan.video.pathExtension.lowercased() == "mov" {
            converted = nil
        } else {
            converted = try await exportAsMOV(plan.video)
        }
        let movie = converted ?? plan.video
        defer { if let converted { try? FileManager.default.removeItem(at: converted) } }

        try FileManager.default.createDirectory(at: layerStack, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: segmentation.appendingPathComponent("asset.resource", conformingTo: .data),
            withIntermediateDirectories: true)
        let settling = layerStack.appendingPathComponent("portrait-layer_settling-video.MOV")
        try? FileManager.default.removeItem(at: settling)
        try FileManager.default.copyItem(at: movie, to: settling)
        log("  → live photo: \(plan.name) → portrait-layer_settling-video.MOV "
            + "(\(ByteCountFormatter.string(fromByteCount: fileSize(settling), countStyle: .file)))")

        // The .aar is a container of exactly two members: the descriptor's
        // contents.plist and the video.
        try wrapInAAR(contentsPlist: PosterBoardResources.livePhotoContentsPlist,
                      video: settling,
                      output: segmentation.appendingPathComponent("segmentation.data.aar"))

        guard let thumbnail = plan.thumbnail else {
            throw DriftError("实况照片壁纸需要一帧定格图（.heic）。"
                + "在「视频」标签页选一帧，或者打开循环。")
        }
        // The reference writes the picked bytes over all three slots without
        // looking at what they are; the descriptor's assets are HEIC, so the
        // picker asks for HEIC.
        let thumbBytes = try Data(contentsOf: thumbnail, options: .mappedIfSafe)
        let slots = ["input.segmentation/asset.resource/Adjusted.HEIC",
                     "input.segmentation/asset.resource/proxy.heic",
                     "output.layerStack/portrait-layer_background.HEIC"]
        for slot in slots {
            let destination = contents.appendingPathComponent(slot)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try thumbBytes.write(to: destination)
        }
    }

    // MARK: - `.aar`

    /// `src/controllers/aar/aar.py`, ported.
    ///
    /// An `AA01` archive with two members whose names are baked into their
    /// headers, so both headers are literals and only the payload sizes vary.
    /// The size field is a 2-byte blob while it fits, and the member's subtype
    /// byte flips to `B` (a 4-byte blob) when it does not — which also grows the
    /// header by two and has to be reflected in its own length field.
    static func wrapInAAR(contentsPlist: Data, video: URL, output: URL) throws {
        var first = Self.hex(
            "4141303125005459503146504154500E00636F6E74656E74732E706C697374444154418E13")
        var second = Self.hex(
            "4141303129005459503146504154501200736574746C696E674566666563742E6D6F7644415441F4B8")

        patchSizeField(&first, size: contentsPlist.count, longHeaderLength: 0x27)
        patchSizeField(&second, size: Int(fileSize(video)), longHeaderLength: 0x2B)

        try? FileManager.default.removeItem(at: output)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw DriftError("无法创建 \(output.lastPathComponent)。")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(first))
        try handle.write(contentsOf: contentsPlist)
        try handle.write(contentsOf: Data(second))
        // Streamed, not read: the video is already on disk twice at this point
        // (the descriptor's copy and this one) and a third copy in memory is the
        // difference between working and being killed on a phone.
        let source = try FileHandle(forReadingFrom: video)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 18), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
    }

    /// The reference's size patch, including the 64 KB boundary.
    ///
    /// `header[-2:] = pack('<H', size)` grows to four bytes in the long case,
    /// which is why the byte three from the end — the member's subtype — becomes
    /// `B` (a 4-byte blob) and the header's own length field at index 4 has to be
    /// bumped by two to match.
    private static func patchSizeField(_ header: inout [UInt8],
                                       size: Int,
                                       longHeaderLength: UInt8) {
        if size <= 0xFFFF {
            header[header.count - 2] = UInt8(size & 0xFF)
            header[header.count - 1] = UInt8((size >> 8) & 0xFF)
        } else {
            // `header[-3]`, spelled as the measurement it is.
            header[header.count - 3] = 0x42
            header.removeLast(2)
            header[4] = longHeaderLength
            header.append(contentsOf: [
                UInt8(size & 0xFF),
                UInt8((size >> 8) & 0xFF),
                UInt8((size >> 16) & 0xFF),
                UInt8((size >> 24) & 0xFF),
            ])
        }
    }

    /// Bytes from a hex string, for the two `.aar` headers — the reference spells
    /// them as `bytearray.fromhex(...)` and they stay literal here too.
    private static func hex(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex,
              let next = value.index(index, offsetBy: 2, limitedBy: value.endIndex) {
            bytes.append(UInt8(value[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    // MARK: - Decoding

    /// Every decoded frame, in order, via `AVAssetReader`.
    ///
    /// Sequential decoding rather than `AVAssetImageGenerator`: the generator
    /// seeks to each requested time, so a 400-frame wallpaper would be 400 seeks.
    /// The callback returns `false` to stop early.
    private static func decodeFrames(asset: AVURLAsset,
                                     track: AVAssetTrack,
                                     displaySize: (width: Int, height: Int),
                                     transform: CGAffineTransform,
                                     fps: Double,
                                     duration: CMTime,
                                     log: @escaping @Sendable (String) -> Void,
                                     consume: (CGImage) throws -> Bool) async throws {
        // Count the frames the caller actually took. A reader
        // failure may fall back to the generator only while that
        // count is zero — otherwise the fallback would write
        // frame 0 again over the files already on disk and double
        // the caml list.
        var consumed = 0
        let counting: (CGImage) throws -> Bool = { image in
            guard try consume(image) else { return false }
            consumed += 1
            return true
        }
        if transform == .identity {
            log("  → 逐帧解码：普通读取")
            do {
                try decodeTrack(asset: asset, track: track, consume: counting)
            } catch let failure as DecodeFailure {
                try await fallBackToGenerator(failure, consumed: consumed,
                                              asset: asset, fps: fps,
                                              duration: duration, log: log,
                                              consume: counting)
            }
            return
        }
        do {
            try decodeComposition(asset: asset, track: track,
                                  displaySize: displaySize, transform: transform,
                                  fps: fps, duration: duration, consume: counting)
        } catch let unavailable as CompositionUnavailable {
            // A setup failure falls back from frame 0: `decodeComposition`
            // has consumed nothing at that point. A reader failure after
            // frames were emitted lands in the DecodeFailure catch below
            // and resumes from the break point instead of restarting.
            log("  ⚠️ 旋转视频的合成解码不可用（\(unavailable.message)），"
                + "回退到逐帧生成器（会慢很多）")
            try await decodeWithGenerator(asset: asset, fps: fps, duration: duration,
                                          consume: counting)
        } catch let failure as DecodeFailure {
            try await fallBackToGenerator(failure, consumed: consumed,
                                          asset: asset, fps: fps,
                                          duration: duration, log: log,
                                          consume: counting)
        }
    }

    /// A reader failure is not the end, at the start or midway:
    /// the generator takes a completely different route
    /// (per-frame seeks, damaged frames skipped), so it can
    /// either take over from frame 0 or — the 2026-11-28 iPad
    /// [H264-4K] case, AVFoundationErrorDomain -11819 part-way
    /// through — resume exactly where the reader died. It writes
    /// through the same counting consumer, so the frames already
    /// on disk keep their numbers and nothing is written twice;
    /// the frames it cannot get are simply missing from the
    /// sequence, which stays valid, just shorter.
    private static func fallBackToGenerator(_ failure: DecodeFailure,
                                            consumed: Int,
                                            asset: AVURLAsset,
                                            fps: Double, duration: CMTime,
                                            log: @escaping @Sendable (String) -> Void,
                                            consume: (CGImage) throws -> Bool) async throws {
        if consumed == 0 {
            log("  ⚠️ 逐帧读取失败（\(failure.message)），还没解出帧，"
                + "回退到逐帧生成器（会慢很多）")
        } else {
            log("  ⚠️ 逐帧读取中途失败（\(failure.message)），已解出 \(consumed) 帧，"
                + "从断点接着用逐帧生成器续解（会慢一些）")
        }
        try await decodeWithGenerator(asset: asset, fps: fps, duration: duration,
                                      startingAt: consumed, consume: consume)
    }

    private static func decodeTrack(asset: AVURLAsset, track: AVAssetTrack,
                                    consume: (CGImage) throws -> Bool) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DecodeFailure(error)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw DecodeFailure(message: "这台设备加不上这个视频的帧输出")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw DecodeFailure(reader.error)
        }
        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr,
                  let image else { continue }
            if try !consume(image) { break }
        }
        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            throw DecodeFailure(reader.error)
        }
    }

    private static func decodeComposition(asset: AVURLAsset, track: AVAssetTrack,
                                          displaySize: (width: Int, height: Int),
                                          transform: CGAffineTransform,
                                          fps: Double, duration: CMTime,
                                          consume: (CGImage) throws -> Bool) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompositionUnavailable(message: error.localizedDescription)
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        // The track's stored pixels are unrotated. A video composition
        // renders them through the preferred transform at the display
        // size, which is exactly what the framing box and lock preview
        // show; the old track-output path would flash them sideways.
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: CGFloat(displaySize.width),
                                        height: CGFloat(displaySize.height))
        composition.frameDuration = CMTime(seconds: 1.0 / max(1.0, fps),
                                            preferredTimescale: 600)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: settings)
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CompositionUnavailable(message: "composition output was refused")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CompositionUnavailable(message: reader.error?.localizedDescription
                ?? "reader refused to start")
        }
        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr,
                  let image else { continue }
            if try !consume(image) { break }
        }
        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            throw DecodeFailure(reader.error)
        }
    }

    /// Last-resort path: `AVAssetImageGenerator` applies the
    /// preferred transform itself and skips frames it cannot
    /// decode, at the cost of seeking to every frame. Serves the
    /// composition setup refusal (from frame 0), a reader that
    /// fails before its first frame, and — via `startingAt` — a
    /// reader that dies midway, resuming at the break point.
    private static func decodeWithGenerator(asset: AVURLAsset, fps: Double,
                                            duration: CMTime,
                                            startingAt startIndex: Int = 0,
                                            consume: (CGImage) throws -> Bool) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let total = max(1, Int((CMTimeGetSeconds(duration) * fps).rounded()))
        for index in startIndex..<total {
            let time = CMTime(seconds: Double(index) / max(1.0, fps),
                              preferredTimescale: 600)
            do {
                let frame = try await generator.image(at: time)
                if try !consume(frame.image) { break }
            } catch {
                // A seek can fail on a damaged frame; keep going so one
                // bad sample does not lose the whole video.
                continue
            }
        }
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: jpegQuality) else {
            throw DriftError("解码后的某一帧无法编码为 JPEG。")
        }
        return data
    }

    /// `nominalFrameRate`, with the two fallbacks a track can need.
    ///
    /// `load(…)` rather than the synchronous properties: those are still
    /// reachable but deprecated since iOS 16, and this is their last caller.
    private static func framesPerSecond(of track: AVAssetTrack) async throws -> Double {
        let nominal = Double(try await track.load(.nominalFrameRate))
        if nominal > 0 { return nominal }
        let minimum = CMTimeGetSeconds(try await track.load(.minFrameDuration))
        if minimum > 0 { return 1 / minimum }
        return 30
    }

    // MARK: - MOV conversion

    /// `convert_to_mov` — ffmpeg's `-c:v copy -c:a copy -f mov`, as
    /// `AVAssetExportPresetPassthrough`: rewrapping the container without
    /// touching a frame, which is what "copy" means for both.
    private static func exportAsMOV(_ video: URL) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard-\(UUID().uuidString).mov")
        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw DriftError("\(video.lastPathComponent) 无法重新封装为 .mov。")
        }
        do {
            try await session.export(to: output, as: .mov)
        } catch {
            throw DriftError("无法把 \(video.lastPathComponent) 重新封装为 .mov："
                + error.localizedDescription)
        }
        return output
    }

    // MARK: - Small helpers

    /// Write an embedded resource tree under `root`.
    private static func write(_ files: [String: Data], into root: URL) throws {
        let fm = FileManager.default
        for (relative, data) in files.sorted(by: { $0.key < $1.key }) {
            let destination = URL(fileURLWithPath: root.path + "/" + relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: destination)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
