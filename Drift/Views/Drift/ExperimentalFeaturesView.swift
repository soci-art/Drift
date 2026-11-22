import SwiftUI

/// The experimental features page (collection #329, Grace 2026-11-14):
/// reached from Settings, next to 关于此 App. It used to hold the two
/// switches — 内核直刷 and 恢复刷 — and nowhere else.
///
/// Both features have since graduated: 内核直刷 on the formal line
/// first, then 恢复刷, which Grace ordered opened as a regular
/// feature on 2026-11-22 after its spare-device proof on the Alpha
/// research line. On her instruction the same day, the page itself
/// stays — the entry in Settings remains — but both switches are
/// gone: each feature is simply there when the device qualifies,
/// judged by system and model like every other route, and neither
/// wears the 实验 badge any more. What is left is a short record of
/// the two graduations, so a user who remembers the switches is not
/// left wondering where they went.
struct ExperimentalFeaturesView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text("内核直刷")
                    Text("给 iOS 17 / 18 用的直刷方式，不用配对、不用开隧道、不要求签名。已经是正式功能：在主页选了就能用，没有开关了。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text("恢复刷")
                    Text("通过恢复方式刷入壁纸，只认 iOS 27。已经是正式功能：在主页选了就能用，没有开关了。刷之前先整机备份、关掉「查找」。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("实验性功能")
        .navigationBarTitleDisplayMode(.inline)
    }
}
