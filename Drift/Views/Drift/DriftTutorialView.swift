import SwiftUI

/// The tutorial home (collection #230/#231/#236, Grace 2026-11-12): one
/// card per flashing channel, and nothing else. It is reached from
/// the Home page's entry card between the status card and the method card
/// — the setup wizard is unchanged and Settings carries no tutorial entry
/// any more (#239). 内核直刷 joined as the fourth card in #329
/// (2026-11-14) and 恢复刷 as the fifth when it opened (2026-11-22);
/// neither has a switch any more — the cards are how a user finds
/// out the methods exist.
///
/// Each card's pill follows the live judgement (#231): 可用 when the
/// channel can run now; for the two tunnel channels, 需要配对和隧道 when
/// the system allows it but pairing/tunnel are not in place; 不可用 when
/// the system itself shuts the channel (or, for 本机直刷, when the signing
/// grants no usable group). An unavailable card still opens — the page
/// explains why and what would have to change.
struct DriftTutorialView: View {
    /// Each channel's standing, judged by the caller (DriftTutorialStates)
    /// at the moment the tutorial is opened. The view itself is pure
    /// display — the same files render unchanged in the simulator
    /// preview target with canned states.
    let states: [TutorialChannel: TutorialChannelState]

    var body: some View {
        ZStack {
            DriftBackground()
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(TutorialChannel.allCases) { channel in
                        NavigationLink {
                            DriftTutorialChannelView(channel: channel,
                                                     state: states[channel] ?? .systemBlocked)
                        } label: {
                            channelCard(channel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .driftPageWidth()
            }
        }
        .navigationTitle("使用教程")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func channelCard(_ channel: TutorialChannel) -> some View {
        let state = states[channel] ?? .systemBlocked
        return HStack(spacing: 12) {
            Image(systemName: channel.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(channel.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if channel == .restore {
                        Text("新")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                Text(channel.subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            DriftPill(text: state.pillText, tint: state.pillTint)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }
}

/// The channels the tutorial teaches. 恢复刷 joined as the fifth
/// card when the route opened on the formal line (Grace,
/// 2026-11-22); before that the sealed route was taught nowhere.
enum TutorialChannel: CaseIterable, Identifiable {
    case noRespring
    case respring
    case local
    case kernel
    case restore

    var id: String { title }

    /// The channel's name and one-liner — the same words the Home
    /// page's method card uses (DriftMethodPick.label / .subtitle);
    /// duplicated here so this file stays display-only.
    var title: String {
        switch self {
        case .noRespring: return "免注销直刷"
        case .respring: return "注销直刷"
        case .local: return "本机直刷"
        case .kernel: return "内核直刷"
        case .restore: return "恢复刷"
        }
    }

    var subtitle: String {
        switch self {
        case .noRespring: return "隧道写入 · 刷完即生效，无需注销"
        case .respring: return "隧道写入 · 注销后生效"
        case .local: return "本机写入，免配对、免隧道"
        case .kernel: return "内核写入，免配对、免隧道"
        case .restore: return "备份写回 · 拉取整机备份，只换壁纸再写回"
        }
    }

    var icon: String {
        switch self {
        case .noRespring: return "bolt.fill"
        case .respring: return "arrow.clockwise"
        case .local: return "iphone"
        case .kernel: return "cpu"
        case .restore: return "arrow.counterclockwise.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .noRespring: return .blue
        case .respring: return .purple
        case .local: return .green
        case .kernel: return .orange
        case .restore: return .red
        }
    }

    /// The restore route rides the same pairing + tunnel as the
    /// two tunnel channels (its connection conditions are the trio,
    /// Grace, 2026-11-17), so it shares their prepare cards.
    var isTunnel: Bool { self == .noRespring || self == .respring || self == .restore }
}

/// Where one channel stands for this phone right now, in the tutorial's
/// spoken states (#231; 还没打开 added with the kernel channel in
/// #329). The mapping from the live judgement lives in
/// DriftTutorialStates; this enum is only the spoken result.
enum TutorialChannelState {
    case ready
    case needsSetup
    case systemBlocked
    case groupBlocked
    /// The method's own switch is off (内核直刷 before its
    /// 实验性功能 switch is turned on, #329).
    case notEnabled

    /// The tutorial-home pill (#231).
    var pillText: String {
        switch self {
        case .ready: return "可用"
        case .needsSetup: return "需要配对和隧道"
        case .systemBlocked, .groupBlocked: return "不可用"
        case .notEnabled: return "还没打开"
        }
    }

    var pillTint: Color {
        switch self {
        case .ready: return .green
        case .needsSetup, .notEnabled: return .orange
        case .systemBlocked, .groupBlocked: return .secondary
        }
    }
}
