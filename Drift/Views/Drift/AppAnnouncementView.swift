import SwiftUI

/// The in-app update announcement (#178): the build's own notes,
/// shown once per build, dismissed with the single 确定 button.
struct AppAnnouncementView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppAnnouncement.title)
                .font(.title2.weight(.bold))
                .padding(.top, 8)
            ForEach(AppAnnouncement.lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text("·").font(.body.weight(.bold))
                    Text(line).font(.body)
                }
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Text("确定")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}
