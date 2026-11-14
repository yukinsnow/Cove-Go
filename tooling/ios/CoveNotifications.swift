import Flutter
import UIKit
import UserNotifications

// Local notifications only. No APNs entitlement, token upload or background claims.
final class CoveNotifications: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel
  private var pendingTap: [String: Any]?
  private var listening = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cove/notifications", binaryMessenger: registrar.messenger())
    let plugin = CoveNotifications(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    UNUserNotificationCenter.current().delegate = plugin
    registrar.publish(plugin)
  }

  init(channel: FlutterMethodChannel) { self.channel = channel; super.init() }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "status":
      center.getNotificationSettings { settings in
        DispatchQueue.main.async { result(self.status(settings)) }
      }
    case "request":
      center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
        if let error = error {
          DispatchQueue.main.async { result(FlutterError(code: "permission", message: error.localizedDescription, details: nil)) }
          return
        }
        center.getNotificationSettings { settings in
          DispatchQueue.main.async { result(self.status(settings)) }
        }
      }
    case "listen":
      listening = true
      result(pendingTap)
      pendingTap = nil
    case "show":
      guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String, !id.isEmpty,
            let target = args["target"] as? [String: Any] else {
        result(FlutterError(code: "invalid", message: "Invalid notification", details: nil)); return
      }
      let content = UNMutableNotificationContent()
      content.title = String((args["title"] as? String ?? "Cove-Go").prefix(100))
      content.body = String((args["body"] as? String ?? "").prefix(300))
      content.sound = .default
      content.threadIdentifier = args["thread"] as? String ?? "cove"
      content.userInfo = ["coveTarget": target]
      center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
        DispatchQueue.main.async {
          if let error = error { result(FlutterError(code: "show", message: error.localizedDescription, details: nil)) }
          else { result(nil) }
        }
      }
    case "cancelAll":
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      result(nil)
    case "settings":
      let settingsURL: String
      if #available(iOS 16.0, *) { settingsURL = UIApplication.openNotificationSettingsURLString }
      else { settingsURL = UIApplication.openSettingsURLString }
      guard let url = URL(string: settingsURL) else { result(false); return }
      UIApplication.shared.open(url, options: [:]) { result($0) }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func status(_ settings: UNNotificationSettings) -> [String: Any] {
    let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral
    return ["native": true, "enabled": allowed, "notDetermined": settings.authorizationStatus == .notDetermined]
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
          let target = response.notification.request.content.userInfo["coveTarget"] as? [String: Any] else {
      completionHandler(); return
    }
    DispatchQueue.main.async {
      if self.listening { self.channel.invokeMethod("tap", arguments: target) }
      else { self.pendingTap = target }
      completionHandler()
    }
  }
}
