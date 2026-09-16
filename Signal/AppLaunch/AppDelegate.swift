//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Receives app lifecycle events from UIKit, and forwards them to
/// ``AppLifecycleManager``.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private let lifecycleManager = AppLifecycleManager.shared

    var window: UIWindow? {
        get { lifecycleManager.window }
        set { lifecycleManager.window = newValue }
    }

    // MARK: - Lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        return lifecycleManager.didFinishLaunching(launchOptions: launchOptions)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        lifecycleManager.willEnterForeground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        lifecycleManager.didBecomeActive()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        lifecycleManager.willResignActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        lifecycleManager.didEnterBackground()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        lifecycleManager.didReceiveMemoryWarning()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        lifecycleManager.willTerminate()
    }

    // MARK: - Orientation

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?,
    ) -> UIInterfaceOrientationMask {
        return lifecycleManager.supportedInterfaceOrientations(for: window)
    }

    // MARK: - Notifications

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        lifecycleManager.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        lifecycleManager.didFailToRegisterForRemoteNotifications(error: error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void,
    ) {
        lifecycleManager.didReceiveRemoteNotification(userInfo, completionHandler: completionHandler)
    }

    // MARK: - Handoff

    @available(iOS, deprecated: 13.0)
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void,
    ) -> Bool {
        return lifecycleManager.handle(userActivity: userActivity)
    }

    // MARK: - Shortcut Items

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void,
    ) {
        lifecycleManager.performAction(for: shortcutItem, completionHandler: completionHandler)
    }

    // MARK: - URL Handling

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        AssertIsOnMainThread()
        return lifecycleManager.handleOpenUrl(url)
    }
}
