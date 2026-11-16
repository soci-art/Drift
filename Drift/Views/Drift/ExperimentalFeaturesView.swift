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
///   silent. On the formal line the channel is suspended (#341,
///   Grace, 2026-11-16): an iOS 17 / 18 device tapping the switch
///   on gets the closure notice instead of the confirmation, and
///   the switch stays off — see `KernelDirectPremise.channelSuspended`.
/// * 恢复刷 — the switch is a surface only: any tap answers
///   「恢复刷暂不可用」 and the switch stays off. The restore seal
///   itself is untouched (`DriftRestoreGate` still decides), this
///   page only gives the feature a home now that its Home row is
///   gone (#329).
struct ExperimentalFeaturesView: View {
    @AppStorage(KernelDirectPremise.enabledKey) private var kernelEnabled = false
    @State private var confirmKernelOn = false
    @State private var kernelSuspendedNotice = false
    @State private var restoreNotice = false

    /// This device is one of the kernel generations (iOS 17 / 18) —
    /// the only systems the kernel channel could ever serve, and so
    /// the only ones the formal line's suspension notice addresses.
    private var isKernelGeneration: Bool {
        let major = Int(WorseQueryEscape.processVersion.split(separator: ".").first ?? "") ?? 0
        return major == 17 || major == 18
    }

    /// Turning the kernel switch on goes through the confirmation
    /// sheet; the stored value only changes when the user confirms.
    /// On a kernel-generation device the formal line's suspension
    /// answers instead (#341): the closure notice, and the switch
    /// stays off.
    private var kernelBinding: Binding<Bool> {
        Binding(
            get: { kernelEnabled },
            set: { newValue in
                if newValue {
                    if isKernelGeneration {
                        kernelSuspendedNotice = true
                    } else {
                        confirmKernelOn = true
                    }
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
                        Text("给 iOS 17 / 18 用的直刷方式，不用配对、不用开隧道、不要求签名。")
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
        // #341 (Grace, 2026-11-16): the suspension notice is two
        // lines and one button — no actions of its own, and the
        // sheet's dismiss button reads 「确定」, not 「取消」.
        .driftActionSheet(
            isPresented: $kernelSuspendedNotice,
            title: "内核直刷暂时关闭",
            message: "如需启用请开启预发行版开关并检查更新",
            actions: [],
            cancelTitle: "确定")
        .driftActionSheet(
            isPresented: $restoreNotice,
            title: "提示",
            message: "恢复刷暂不可用。",
            actions: [
                DriftSheetAction("知道了") {},
            ])
    }
}
