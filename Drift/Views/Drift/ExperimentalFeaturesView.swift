import SwiftUI

/// The experimental features page (collection #329, Grace 2026-11-14):
/// reached from Settings, next to 关于此 App. Two switches live here
/// and nowhere else:
///
/// * 内核直刷 — off by default. Turning it on asks first (the sheet's
///   wording is Grace's); only then does the method appear in Home's
///   method list and its status group lead the status card. Turning
///   it off is silent, and a stored kernel pick falls back to
///   自动选择 (handled in `DriftJudge.judge`).
/// * 恢复刷 — the switch is a surface only: any tap answers
///   「恢复刷暂不可用」 and the switch stays off. The restore seal
///   itself is untouched (`DriftRestoreGate` still decides), this
///   page only gives the feature a home now that its Home row is
///   gone (#329).
struct ExperimentalFeaturesView: View {
    @AppStorage(KernelDirectPremise.enabledKey) private var kernelEnabled = false
    @State private var confirmKernelOn = false
    @State private var restoreNotice = false

    /// Turning the kernel switch on goes through the confirmation
    /// sheet; the stored value only changes when the user confirms.
    private var kernelBinding: Binding<Bool> {
        Binding(
            get: { kernelEnabled },
            set: { newValue in
                if newValue {
                    confirmKernelOn = true
                } else {
                    kernelEnabled = false
                }
            })
    }

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
                        HStack(spacing: 6) {
                            Text("内核直刷")
                            Text("实验")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.16),
                                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .foregroundStyle(.orange)
                        }
                        Text("给 iOS 17 / 18 用的直刷方式，不用配对、不用开隧道。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: kernelBinding).labelsHidden()
                }
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
                Text("实验性功能还在试验阶段，可能不稳定。")
            }
        }
        .navigationTitle("实验性功能")
        .navigationBarTitleDisplayMode(.inline)
        .driftActionSheet(
            isPresented: $confirmKernelOn,
            title: "打开内核直刷？",
            message: "该功能还在试验阶段，确定要打开吗？",
            // Only the affirmative action is listed: the sheet always
            // appends its own 「取消」 below the actions, so a listed
            // 取消 would show twice (Grace's catch, 2026-11-14).
            actions: [
                DriftSheetAction("确定") { kernelEnabled = true },
            ])
        .driftActionSheet(
            isPresented: $restoreNotice,
            title: "提示",
            message: "恢复刷暂不可用。",
            actions: [
                DriftSheetAction("知道了") {},
            ])
    }
}
