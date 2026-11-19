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
/// * 恢复刷 — a placeholder switch on the shipped lines (Grace,
///   2026-11-19): the route is sealed behind `DriftRestoreGate`,
///   so this switch is kept off and any attempt to move it answers
///   「暂不可用」. It exists so the Home pick's go-turn-it-on
///   reminder has somewhere to point. On the Alpha research line
///   the gate is open and this same switch is real (stored in
///   `RestoreFlashPremise`), behind a risk-worded confirmation —
///   the route opened here with no Home surgery, as planned.
struct ExperimentalFeaturesView: View {
    @EnvironmentObject private var session: DriftSession
    @AppStorage(KernelDirectPremise.enabledKey) private var kernelEnabled = false
    @AppStorage(RestoreFlashPremise.enabledKey) private var restoreEnabled = false
    @State private var confirmKernelOn = false
    @State private var confirmRestoreOn = false

    /// The restore switch, per line. On the shipped lines it never
    /// turns on: it reads as off, and moving it only answers
    /// 「暂不可用」 (Grace, 2026-11-19) — nothing is stored, there is
    /// no on state to keep. On the Alpha line it is a real switch:
    /// turning it on goes through the risk-worded confirmation sheet
    /// and the stored value is `RestoreFlashPremise`'s; turning it
    /// off is silent, like the kernel switch.
    private var restoreBinding: Binding<Bool> {
        if AppVersion.channel == .alpha {
            return Binding(
                get: { restoreEnabled },
                set: { newValue in
                    if newValue {
                        confirmRestoreOn = true
                    } else {
                        restoreEnabled = false
                    }
                })
        }
        return Binding(
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
                        Text(AppVersion.channel == .alpha
                             ? "通过恢复方式刷入壁纸。研究功能，只在备用机上用：先干跑对账，确认后才写回。"
                             : "通过恢复方式刷入壁纸。")
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
        .driftActionSheet(
            isPresented: $confirmRestoreOn,
            title: "打开恢复刷？",
            message: "恢复刷还在研究阶段，没有在真机上验证过。打开后刷入也只会先干跑对账，真正写回前还要再确认一次。只在备用机上打开，主力机不要开。",
            actions: [
                DriftSheetAction("确定") { restoreEnabled = true },
            ])
    }
}
