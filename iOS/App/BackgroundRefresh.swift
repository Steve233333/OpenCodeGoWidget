import Foundation
import BackgroundTasks
import WidgetKit

enum IOSBackgroundRefresh {
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PlatformConfig.backgroundRefreshID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func schedule() {
        guard IOSPreferences.backgroundRefreshEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PlatformConfig.backgroundRefreshID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: PlatformConfig.backgroundRefreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            schedule()
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PlatformConfig.backgroundRefreshID)
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            do {
                _ = try await IOSUsageRefresher.refresh()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
