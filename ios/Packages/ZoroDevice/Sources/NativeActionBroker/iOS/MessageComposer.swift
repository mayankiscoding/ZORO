// UNVERIFIED-ON-HOST
// MessageUI: MFMessageComposeViewController.canSendText(), recipients, body, messageComposeDelegate,
// MFMessageComposeViewControllerDelegate.messageComposeViewController(_:didFinishWith:) (iOS 4+).
#if os(iOS) && canImport(MessageUI)
import MessageUI
import UIKit

/// Presents the system message composer from the view controller the app shell provides.
@MainActor
public final class SystemMessageComposer: NSObject, MessageComposing, MFMessageComposeViewControllerDelegate {
    private let presenter: @MainActor () -> UIViewController?
    private var pending: CheckedContinuation<MessageComposeOutcome, Never>?
    private var shown: MFMessageComposeViewController?

    /// `presenter` returns the top-most view controller.
    public init(presenter: @escaping @MainActor () -> UIViewController?) {
        self.presenter = presenter
    }

    public func canSendText() async -> Bool { MFMessageComposeViewController.canSendText() }

    public func compose(recipients: [String], body: String) async -> MessageComposeOutcome {
        guard pending == nil, let host = presenter() else { return .failed }
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = self
        shown = controller
        // The delegate answers on the main actor, after this method suspends below.
        host.present(controller, animated: true)
        return await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    nonisolated public func messageComposeViewController(
        _ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult
    ) {
        MainActor.assumeIsolated {
            shown?.dismiss(animated: true)
            shown = nil
            let outcome: MessageComposeOutcome
            switch result {
            case .sent: outcome = .sent
            case .cancelled: outcome = .cancelled
            default: outcome = .failed
            }
            pending?.resume(returning: outcome)
            pending = nil
        }
    }
}
#endif
