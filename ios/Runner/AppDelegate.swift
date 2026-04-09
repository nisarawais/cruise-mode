import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupDndChannel(engineBridge.pluginRegistry.registrar(forPlugin: "DndPlugin")!)
  }

  private func setupDndChannel(_ registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "nav_study/dnd",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "openFocusSettings":
        // Opens the Focus / Do Not Disturb settings screen
        if let url = URL(string: "App-Prefs:root=DO_NOT_DISTURB"),
           UIApplication.shared.canOpenURL(url) {
          UIApplication.shared.open(url)
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
          // Fallback: open the app's own Settings entry
          UIApplication.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
