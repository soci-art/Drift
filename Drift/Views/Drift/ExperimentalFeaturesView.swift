import SwiftUI

/// The experimental features page (collection #329, Grace 2026-11-14):
/// reached from Settings, next to 关于此 App. Two switches live here
/// and nowhere else:
///
/// * 内核直刷 — off by default. Turning it on asks first (the sheet's
///   wording is Grace's). The method is always listed on Home
///   (Grace, 2026-11-15); while the switch is off its row shows
///   未打开 with a pointer back here, its status group leads the
///   status card only once it is ready, and the judge blocks a
///   kernel pick with the turn-it-on reminder. Turning it off is
///   silent.
/// * 恢复刷 — a placeholder switch (Grace, 2026-11-19): the route
///   itself is still sealed behind `DriftRestoreGate`, so this
///   switch is kept off and any attempt to move it answers
///   「暂不可用」. It exists so the Home pick's go-turn-it-on
///   reminder has somewhere to point, and so the day the restore
///   research lands, the route opens by making this switch real —
///   no Home surgery needed.
struct ExperimentalFeaturesView: View {
    @EnvironmentObject private var session: DriftSession
    @AppStorage(KernelDirectPremise.enabledKey) private var kernelEnabled = false
    @State private var confirmKernelOn = false

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
                        Text("给 iOS 17 / 18 用的直刷方式，不用配对、不用开隧道、不要求签名。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: kernelBinding).labelsHidden()
                }
            } footer: {
                Text("实验性功能还在试验阶段，可能不稳定。")
            }
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
    }
}
