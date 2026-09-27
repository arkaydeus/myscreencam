import AppKit
import MyScreenCamCore
import UserNotifications

/// Posts "export finished" banners with a "Show in Finder" action when the app isn't frontmost.
///
/// Authorization is requested lazily, when the first export of the session starts (never at launch), and
/// never in tests.
@MainActor
final class ExportNotifier: NSObject {
    private nonisolated static let category = "export.finished"
    private nonisolated static let showInFinderAction = "export.showInFinder"
    private nonisolated static let pathKey = "path"

    private var didPrepare = false
    private var authorized = false

    /// True when running under XCTest / Swift Testing or when notifications are switched off for automation.
    private static var isDisabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
            || environment["MYSCREENCAM_DISABLE_NOTIFICATIONS"] == "1"
    }

    /// Registers the category and asks for authorization once. Called when an export starts.
    func prepare() {
        guard !didPrepare, !Self.isDisabled else { return }
        didPrepare = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let show = UNNotificationAction(identifier: Self.showInFinderAction, title: "Show in Finder")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [show], intentIdentifiers: [])
        ])
        Task { [weak self] in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            self?.authorized = granted
        }
    }

    func notifyFinished(name: String, url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Export finished"
        content.body = "\(name) → \(url.lastPathComponent)"
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.pathKey: url.path]
        post(content)
    }

    func notifyFailed(name: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Export failed"
        content.body = "\(name): \(message)"
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        guard didPrepare, authorized, !NSApp.isActive else { return }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.app.error("Couldn't post the export notification: \(error, privacy: .public)") }
        }
    }

    /// The exported file a "Show in Finder" (or banner click) response refers to.
    fileprivate nonisolated static func exportedFile(from response: UNNotificationResponse) -> URL? {
        let content = response.notification.request.content
        guard content.categoryIdentifier == category,
            response.actionIdentifier == showInFinderAction
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let path = content.userInfo[pathKey] as? String
        else { return nil }
        return URL(filePath: path)
    }
}

extension ExportNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let url = Self.exportedFile(from: response) else { return }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
