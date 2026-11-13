// UNVERIFIED-ON-HOST
// One system-scheduled processing task for the on-device photo index: the system runs it when the
// iPhone is idle and charging; it stops when the system says so. Nothing else runs in the background.
// Checked against Apple's documentation: BGTaskScheduler.shared.register(forTaskWithIdentifier:using:launchHandler:),
// BGProcessingTaskRequest(identifier:), requiresExternalPower, requiresNetworkConnectivity,
// BGTaskScheduler.submit(_:) throws, BGTask.expirationHandler, BGTask.setTaskCompleted(success:).
// Info.plist: BGTaskSchedulerPermittedIdentifiers contains the identifier; UIBackgroundModes "processing".
#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
import Foundation

enum PhotoIndexingTask {
    static let identifier = "app.zoro.photo-index"

    @MainActor
    static func register(model: PhoneAppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                guard let service = await model.waitUntilReady()?.photoService else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let ok = (try? await service.indexNow()) != nil
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
