import SwiftUI
import UIKit

/// The deep-repair sheet (#258–#261, Grace 2026-11-12): opened from
/// the black「深度修复」pill on the pack detail page, beside the
/// structural「壁纸修复」. It first takes stock — what the structural
/// repair already did to this pack (#260), what structural problems
/// still stand, and what a deep-repair run would do — and only then
/// offers the run. The engine is PackDeepRepair; this view is its
/// stock-take display and progress surface, nothing more.
struct PackDeepRepairView: View {
    let pack: PosterBoardTendie
    /// The repaired product joins the imports list back home.
    let onDone: (PosterBoardTendie) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var report: PackDeepRepair.Report?
    /// The held stock-take: its extracted tree is what the run below
    /// works on, instead of unpacking the pack a second time.
    @State private var session: PackDeepRepair.Session?
    @State private var running = false
    @State private var progress: Double = 0
    @State private var doneLines: [String]?
    @State private var donePackName: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { DriftBackground() }
            .navigationTitle("深度修复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            let canvas = PackDeepRepair.Canvas.current
            let opened = await Task.detached {
                await PackDeepRepair.openSession(pack, canvas: canvas)
            }.value
            session = opened
            report = opened.report
        }
        .onDisappear {
            session?.discard()
            session = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            Text("出错了").font(.headline)
            Text(failure).font(.subheadline).foregroundStyle(.secondary)
        } else if let doneLines {
            Text("修好了").font(.headline)
            if let donePackName {
                Text("修好的包已放进壁纸列表，名字是「\(donePackName)」。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(doneLines, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.subheadline)
            }
        } else if running {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在深度修复").font(.headline)
                Text("请勿熄屏或退出 App").font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if let report {
            stockTake(report)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在检查这个包…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func stockTake(_ report: PackDeepRepair.Report) -> some View {
        if report.priorRepairMark {
            Text("先说前面的「壁纸修复」").font(.headline)
            if report.priorRepairLines.isEmpty {
                Text("这个包是「壁纸修复」修好的成品，深度修复在它修好的基础上再做。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("这个包是「壁纸修复」修好的成品，它当时修了这些：")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(report.priorRepairLines, id: \.self) { line in
                    Label(line, systemImage: "wrench.and.screwdriver")
                        .font(.subheadline)
                }
            }
        }
        if !report.structuralBlocking.isEmpty {
            Text("结构问题还在").font(.headline)
            Text("下面这些是结构问题，是「壁纸修复」的活。先把它修好，再来深度修复——不然修出来的包还是刷不进去。")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(report.structuralBlocking, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
            }
        } else if report.fixes.isEmpty {
            Text("这个包没查到需要深度修复的地方。")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            Text("这次会做的").font(.headline)
            ForEach(report.fixes, id: \.self) { line in
                Label(line, systemImage: "wand.and.stars")
                    .font(.subheadline)
            }
            Button {
                run()
            } label: {
                Text("开始深度修复")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.black))
            }
            .padding(.top, 4)
        }
    }

    private func run() {
        running = true
        progress = 0
        failure = nil
        let canvas = PackDeepRepair.Canvas.current
        let target = pack
        let held = session
        session = nil
        Task {
            do {
                let result = try await Task.detached {
                    // The held stock-take's tree when there is one —
                    // the pack is not unpacked or scanned twice.
                    if let held {
                        do {
                            return try await PackDeepRepair.repair(session: held) { phase in
                                Task { @MainActor in progress = phase }
                            }
                        } catch {
                            held.discard()
                            throw error
                        }
                    }
                    return try await PackDeepRepair.repair(target, canvas: canvas) { phase in
                        Task { @MainActor in progress = phase }
                    }
                }.value
                doneLines = result.done
                donePackName = result.pack.name
                onDone(result.pack)
            } catch {
                failure = error.localizedDescription
            }
            running = false
        }
    }
}

/// The black pill from the approved mock (deep-repair2.png): same
/// capsule shape and padding family as the neighbouring glass pills,
/// filled black so the two repairs read as neighbours, not twins.
struct DeepRepairPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.65 : 1)))
    }
}

extension PackDeepRepair.Canvas {
    /// The canvas of the screen this app is actually on — the
    /// foreground-active scene first, exactly the poster the video
    /// flow already trusts. Read on the main actor from the view.
    @MainActor
    static var current: PackDeepRepair.Canvas {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                let rank: (UIScene.ActivationState) -> Int = {
                    switch $0 {
                    case .foregroundActive: return 0
                    case .foregroundInactive: return 1
                    default: return 2
                    }
                }
                return rank(lhs.activationState) < rank(rhs.activationState)
            }
        let screen = scenes.first?.screen ?? UIScreen.main
        let bounds = screen.bounds
        return PackDeepRepair.Canvas(
            width: max(1, Int(bounds.width.rounded())),
            height: max(1, Int(bounds.height.rounded())),
            scale: max(1, Int(screen.scale.rounded())))
    }
}
