import SwiftUI
import UIKit
import NostrSDK

@main
struct ClaveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            print("[APNs] Authorization granted: \(granted), error: \(String(describing: error))")
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[APNs] Device token: \(token)")
        SharedConstants.sharedDefaults.set(token, forKey: SharedConstants.deviceTokenKey)

        // Auto-register with proxy if URL is saved
        autoRegisterWithProxy(token: token)
    }

    private func autoRegisterWithProxy(token: String, attempt: Int = 1) {
        guard let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey),
              !proxyURL.isEmpty,
              let url = URL(string: "\(proxyURL)/register") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("[APNs] Auto-registered with proxy")
            } else if attempt < 3 {
                print("[APNs] Proxy registration attempt \(attempt) failed, retrying...")
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt * 2)) {
                    self?.autoRegisterWithProxy(token: token, attempt: attempt + 1)
                }
            } else {
                print("[APNs] Proxy registration failed after 3 attempts: \(error?.localizedDescription ?? "unknown")")
            }
        }.resume()
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] Failed to register: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])  // suppress display
    }
}
