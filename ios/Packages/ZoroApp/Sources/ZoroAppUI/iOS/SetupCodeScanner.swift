// UNVERIFIED-ON-HOST
// Scans the setup QR code (a zoro://pair link) with VisionKit's DataScannerViewController.
// Checked against Apple's documentation: DataScannerViewController (iOS 16+),
// init(recognizedDataTypes:qualityLevel:recognizesMultipleItems:isHighFrameRateTrackingEnabled:
// isPinchToZoomEnabled:isGuidanceEnabled:isHighlightingEnabled:), RecognizedDataType.barcode(symbologies:),
// isSupported / isAvailable, startScanning() throws, DataScannerViewControllerDelegate
// dataScanner(_:didAdd:allItems:), RecognizedItem.barcode(_) with payloadStringValue.
// Needs NSCameraUsageDescription in the app's Info.plist; the camera prompt appears in context, when
// the owner taps "Scan the setup QR code".
#if os(iOS) && canImport(VisionKit)
import SwiftUI
import Vision
import VisionKit
import ZoroDesign

/// The scanner sheet. Calls `onFound` once with the first valid `zoro://pair` link.
public struct SetupCodeScanner: View {
    let onFound: (PairingLink) -> Void
    @State private var message: String?

    public init(onFound: @escaping (PairingLink) -> Void) {
        self.onFound = onFound
    }

    public var body: some View {
        Group {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ScannerRepresentable { payload in
                    switch SetupCodePayload.parse(payload) {
                    case .success(let link): onFound(link)
                    case .failure(let error): message = error.errorDescription
                    }
                }
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    if let message {
                        Text(message).zoroText(.body).padding().background(.regularMaterial, in: Capsule()).padding()
                    }
                }
            } else {
                ZoroStateView(.error, message: "This iPhone can't scan right now. Check camera access in Settings, or type the address and code.")
            }
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        // Started after creation, not inside makeUIViewController; isScanning keeps it to one start.
        if !controller.isScanning { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Void
        init(onPayload: @escaping (String) -> Void) { self.onPayload = onPayload }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    onPayload(payload)
                    return
                }
            }
        }
    }
}
#endif
