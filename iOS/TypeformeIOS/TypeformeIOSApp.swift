import SwiftUI
import UIKit

private extension Notification.Name {
    static let typeformeOpenURL = Notification.Name("TypeformeOpenURL")
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        NotificationCenter.default.post(
            name: .typeformeOpenURL,
            object: url,
            userInfo: [
                "sourceApplication": options[.sourceApplication] as? String as Any
            ]
        )
        return true
    }
}

@main
struct TypeformeIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .task {
                    await state.bootstrap()
                }
                .onReceive(NotificationCenter.default.publisher(for: .typeformeOpenURL)) { notification in
                    guard let url = notification.object as? URL else { return }
                    let sourceApplication = notification.userInfo?["sourceApplication"] as? String
                    Task { await state.handleOpenURL(url, sourceApplication: sourceApplication) }
                }
        }
    }
}
