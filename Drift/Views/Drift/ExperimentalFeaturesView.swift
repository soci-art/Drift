import SwiftUI

/// The experimental features page keeps only the sealed restore entry.
/// The restore gate itself remains closed in DriftRestoreGate.
struct ExperimentalFeaturesView: View {
    @State private var restoreNotice = false

    /// The restore switch never turns on: every tap is answered
    /// with the unavailable notice and it springs back off.
    private var restoreBinding: Binding<Bool> {
        Binding(
            get: { false },
            set: { _ in restoreNotice = true })
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("恢复刷")
                        Text("通过恢复方式刷入壁纸。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: restoreBinding).labelsHidden()
                }
            } footer: {
                Text("恢复刷暂不可用。")
            }
        }
        .navigationTitle("实验性功能")
        .navigationBarTitleDisplayMode(.inline)
        .driftActionSheet(
            isPresented: $restoreNotice,
            title: "提示",
            message: "恢复刷暂不可用。",
            actions: [
                DriftSheetAction("知道了") {},
            ])
    }
}
