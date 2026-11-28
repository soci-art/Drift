import UIKit

/// Drift's share extension: the thin end of the share-sheet route
/// (spec: SHARE-EXTENSION-SPEC.md).
///
/// It does exactly three things: show what was shared, copy the file
/// into the App Group inbox (`ShareInbox`), and say that Drift will
/// import it on next launch. It never unpacks or imports — a share
/// extension's memory ceiling is far below what a big pack takes to
/// open, and the app's own import pipeline (with its auto-repair) is
/// the one place that work belongs.
final class ShareViewController: UIViewController {
    /// The attachment types this extension accepts, most specific
    /// first. They mirror the activation rule in Info.plist.
    private static let acceptedTypeIdentifiers = [
        "com.sociart.drift.tendies",
        "public.zip-archive",
        "com.pkware.zip-archive",
    ]

    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    /// Whether the file landed in the inbox — the button then
    /// completes the request; before that (or after a failure) it
    /// cancels, so the user is never trapped on this sheet.
    private var received = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.text = "壁纸包"

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "正在收下…"

        doneButton.setTitle("取消", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(doneTapped),
                             for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [nameLabel, statusLabel,
                                                   doneButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])

        receive()
    }

    /// Find the first attachment this extension accepts and copy it
    /// into the inbox. The provider's temporary file is deleted when
    /// its handler returns, so the copy happens inside the handler.
    private func receive() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first(where: { provider in
                  Self.acceptedTypeIdentifiers.contains {
                      provider.hasItemConformingToTypeIdentifier($0)
                  }
              }),
              let typeIdentifier = Self.acceptedTypeIdentifiers.first(where: {
                  provider.hasItemConformingToTypeIdentifier($0)
              })
        else {
            finish(success: false, message: "没有收到壁纸包文件。")
            return
        }

        var name = provider.suggestedName ?? "壁纸包"
        if (name as NSString).pathExtension.isEmpty {
            name += typeIdentifier == "com.sociart.drift.tendies"
                ? ".tendies" : ".zip"
        }
        nameLabel.text = name

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) {
            [weak self] url, _ in
            guard let self else { return }
            guard let url else {
                DispatchQueue.main.async {
                    self.finish(success: false,
                                message: "这个文件读不出来，换个 App 再分享一次试试。")
                }
                return
            }
            guard let inbox = ShareInbox.writableInboxDirectory() else {
                DispatchQueue.main.async {
                    self.finish(success: false,
                                message: "这个签名没有可用的共享空间，收不下。"
                                    + "可以改在文件 App 里对这个包点「打开方式」，选 Drift。")
                }
                return
            }
            let destination = ShareInbox.uniqueDestination(in: inbox,
                                                           name: name)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                let size = (try? destination.resourceValues(
                    forKeys: [.fileSizeKey]))?.fileSize ?? 0
                DispatchQueue.main.async {
                    self.nameLabel.text =
                        "\(name)（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）"
                    self.finish(success: true,
                                message: "已收下。打开 Drift 就会自动导入。")
                }
            } catch {
                DispatchQueue.main.async {
                    self.finish(success: false,
                                message: "没存进去：\(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(success: Bool, message: String) {
        received = success
        statusLabel.text = message
        doneButton.setTitle(success ? "完成" : "知道了", for: .normal)
    }

    @objc private func doneTapped() {
        if received {
            extensionContext?.completeRequest(returningItems: [],
                                              completionHandler: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(
                domain: "com.sociart.drift.ShareExtension", code: 0))
        }
    }
}
