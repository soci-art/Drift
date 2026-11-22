import SwiftUI

/// The update page (collection #170/#171): current vs latest version,
/// the release notes, ONE download button (the checker picks the
/// route that works), and after the download the system share sheet —
/// save to Files or hand it to a signing app.
struct AppUpdateView: View {
    @ObservedObject private var checker = AppUpdateChecker.shared
    @State private var shareItem: ShareItem?

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// #179 (Grace, 2026-11-11): a refused wireless-data permission is
    /// never re-asked by the system, so a network failure here must
    /// tell the user where to turn it back on.
    private var wirelessDataHint: String {
        "如果之前在弹窗里点了「不允许」，系统不会再问第二次：到 系统设置 → Drift → 无线数据，选「无线局域网与蜂窝数据」，再回来试。"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text("Drift \(checker.currentDisplay)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("最新版本")
                    Spacer()
                    if checker.checking {
                        ProgressView()
                    } else if let latest = checker.latest {
                        Text("Drift \(latest.displayVersion)")
                            .foregroundStyle(checker.updateAvailable ? .primary : .secondary)
                    } else {
                        Text("还没查到").foregroundStyle(.secondary)
                    }
                }
            }

            if let error = checker.checkError {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Text(wirelessDataHint).font(.caption).foregroundStyle(.secondary)
                }
            }

            if checker.updateAvailable, let latest = checker.latest {
                if !latest.notes.isEmpty {
                    Section("这一版改了什么") {
                        Text(latest.notes)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    downloadButton(latest)
                    if !checker.routeNote.isEmpty {
                        Text(checker.routeNote).font(.caption).foregroundStyle(.secondary)
                    }
                    if case .failed(let message) = checker.downloadPhase {
                        Text(message).font(.caption).foregroundStyle(.red)
                        Text(wirelessDataHint).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("下的是未签名 IPA，保存或分享到签名工具里，签好再装。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if checker.latest != nil && !checker.checking && !checker.nightlyUpdateAvailable {
                Section { Text("已经是最新版本了。").foregroundStyle(.secondary) }
            }

            // #339 (Grace, 2026-11-16): with the 预发行版更新 switch
            // on, a newer nightly is offered here as its own section
            // — clearly labelled as the pre-release it is, with its
            // own download. The switch lives in Settings; this page
            // only ever shows what the checker fetched under it.
            if checker.nightlyUpdateAvailable, let nightly = checker.nightlyLatest {
                Section("预发行版") {
                    HStack {
                        Text("最新版本")
                        Spacer()
                        Text("Drift \(nightly.displayVersion)")
                    }
                    Text("来自预发行版（先行测试）：新功能和修复先在那边验，可能不稳定。")
                        .font(.caption).foregroundStyle(.secondary)
                    downloadButton(nightly, nightly: true)
                    if !checker.updateAvailable {
                        if !checker.routeNote.isEmpty {
                            Text(checker.routeNote).font(.caption).foregroundStyle(.secondary)
                        }
                        if case .failed(let message) = checker.downloadPhase {
                            Text(message).font(.caption).foregroundStyle(.red)
                            Text(wirelessDataHint).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("下的是未签名 IPA，保存或分享到签名工具里，签好再装。装上预发行版之后，这个 App 就按预发行版走。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    Task { await checker.refresh() }
                } label: {
                    Label(checker.checking ? "正在检查…" : "重新检查",
                          systemImage: "arrow.clockwise")
                }
                .disabled(checker.checking)
            }
        }
        .navigationTitle("检查更新")
        .navigationBarTitleDisplayMode(.inline)
        // #304: the one flat page background, like every page.
        .scrollContentBackground(.hidden)
        .background { DriftBackground() }
        .task {
            if checker.latest == nil && !checker.checking {
                await checker.refresh()
            }
        }
        // #313: coming back to this page (e.g. after clearing the
        // cache in Settings, which deletes the downloaded IPA) must
        // not leave a share button standing for a vanished file.
        .onAppear { checker.validateDownloadedFile() }
        .sheet(item: $shareItem) { item in
            FileShareSheet(url: item.url)
        }
        .onChange(of: doneURL?.absoluteString) { _, _ in
            if let url = doneURL { shareItem = ShareItem(url: url) }
        }
    }

    private var doneURL: URL? {
        if case .done(let url) = checker.downloadPhase { return url }
        return nil
    }

    @ViewBuilder
    private func downloadButton(_ latest: AppUpdateChecker.ReleaseInfo, nightly: Bool = false) -> some View {
        switch checker.downloadPhase {
        case .working(let fraction, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                // #226: the percentage rides on the byte counts, so
                // the user sees movement even while the total is
                // still unknown — a bare bar that sat at 0% for the
                // whole download read as no progress at all. #311:
                // the percentage is body-sized, not a caption — a
                // progress display the user has to hunt for reads
                // as no progress display.
                if let fraction {
                    Text("正在下载…\(Int(fraction * 100))%")
                        .font(.body.weight(.medium))
                }
                if totalBytes > 0 {
                    Text("已下载 \(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if downloadedBytes > 0 {
                    Text("已下载 \(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .done:
            Button {
                // #313 belt-and-braces: if the file vanished since
                // the page appeared, reset instead of handing a dead
                // URL to the share sheet.
                checker.validateDownloadedFile()
                if let url = doneURL { shareItem = ShareItem(url: url) }
            } label: {
                Label("保存或分享安装包", systemImage: "square.and.arrow.up")
            }
        default:
            Button {
                if nightly { checker.startNightlyDownload() } else { checker.startDownload() }
            } label: {
                Label(nightly ? "下载预发行版 \(latest.displayVersion)" : "下载 Drift \(latest.displayVersion)",
                      systemImage: "arrow.down.circle")
            }
        }
    }
}
