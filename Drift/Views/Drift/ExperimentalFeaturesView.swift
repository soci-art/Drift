import SwiftUI

/// The experimental features page: the restore route remains a
/// placeholder behind its existing unavailable notice.
struct ExperimentalFeaturesView: View {
    @EnvironmentObject private var session: DriftSession
    /// The restore switch never turns on in this build: it reads as
    /// off, and moving it only answers 「暂不可用」 (Grace,
    /// 2026-11-19). Nothing is stored — there is no on state to keep.
    private var restoreBinding: Binding<Bool> {
        Binding(
            get: { false },
            set: { _ in
                session.noticeTitle = "恢复刷"
                session.noticeText = "暂不可用"
            })
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("恢复刷")
                            Text("实验")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.16),
                                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .foregroundStyle(.orange)
                        }
                        Text("通过恢复方式刷入壁纸。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: restoreBinding).labelsHidden()
                }
            }
        }
        .navigationTitle("实验性功能")
        .navigationBarTitleDisplayMode(.inline)
    }
}
