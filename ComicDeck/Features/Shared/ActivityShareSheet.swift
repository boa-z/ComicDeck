import SwiftUI
import UIKit

struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> ActivityShareHostViewController {
        ActivityShareHostViewController(items: items)
    }

    func updateUIViewController(_ uiViewController: ActivityShareHostViewController, context: Context) {
        uiViewController.update(items: items)
    }
}

final class ActivityShareHostViewController: UIViewController {
    private var items: [Any]
    private var hasPresented = false

    init(items: [Any]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .automatic
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentShareIfNeeded()
    }

    func update(items: [Any]) {
        self.items = items
        if isViewLoaded {
            presentShareIfNeeded()
        }
    }

    private func presentShareIfNeeded() {
        guard !hasPresented else { return }
        guard presentedViewController == nil else { return }
        hasPresented = true

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.dismiss(animated: true)
        }
        present(controller, animated: true)
    }
}
