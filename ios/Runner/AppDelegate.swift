import Flutter
import UIKit
import CoreBluetooth
import CoreMotion
import CoreLocation
import AVFoundation
#if canImport(NearbyInteraction)
import NearbyInteraction
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var centralManager: CBCentralManager?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    centralManager = CBCentralManager(delegate: nil, queue: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "body_finder/capabilities",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "scanCapabilities" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.scanCapabilities() ?? [:])
    }
  }

  private func scanCapabilities() -> [String: Any] {
    let motion = CMMotionManager()
    let altimeter = CMAltimeter.isRelativeAltitudeAvailable()
    let location = CLLocationManager.locationServicesEnabled()
    let microphone = AVAudioSession.sharedInstance().isInputAvailable
    let bleState = centralManager?.state ?? .unknown
    let bleHardware = bleState != .unsupported
    let bleReady = bleState == .poweredOn

    #if canImport(NearbyInteraction)
    let uwb = NISession.isSupported
    #else
    let uwb = false
    #endif

    func capability(
      _ type: String,
      hardware: Bool,
      api: Bool,
      measurement: Bool,
      capabilityClass: String,
      quality: Double,
      reason: String? = nil
    ) -> [String: Any] {
      var value: [String: Any] = [
        "sensorType": type,
        "hardwareAvailable": hardware,
        "apiAvailable": api,
        "permissionState": measurement ? "notRequired" : "unknown",
        "measurementAvailable": measurement,
        "capabilityClass": capabilityClass,
        "estimatedQuality": quality,
      ]
      if let reason = reason { value["restrictionReason"] = reason }
      return value
    }

    return [
      "platform": "iOS",
      "platformVersion": UIDevice.current.systemVersion,
      "capabilities": [
        capability("bluetoothLowEnergy", hardware: bleHardware, api: true,
          measurement: bleReady, capabilityClass: "commonAndExposed", quality: 0.55,
          reason: bleReady ? nil : "Bluetooth must be powered on and authorized before active measurements."),
        capability("wifi", hardware: true, api: true, measurement: false,
          capabilityClass: "hardwareApiRestricted", quality: 0.25,
          reason: "iOS does not expose a general-purpose peer RSSI stream equivalent to low-level Wi-Fi scanning."),
        capability("wifiRtt", hardware: true, api: false, measurement: false,
          capabilityClass: "unavailable", quality: 0.0,
          reason: "No universal public iOS Wi-Fi RTT/FTM API is assumed by this app."),
        capability("wifiCsi", hardware: true, api: false, measurement: false,
          capabilityClass: "hardwareApiRestricted", quality: 0.0,
          reason: "No universal public raw CSI API is assumed."),
        capability("uwbRanging", hardware: uwb, api: uwb, measurement: false,
          capabilityClass: "selectedDevices", quality: 0.90,
          reason: uwb ? "Nearby Interaction session and compatible peer are required." : "UWB ranging is unavailable on this device."),
        capability("rawUwb", hardware: uwb, api: false, measurement: false,
          capabilityClass: "hardwareApiRestricted", quality: 0.0,
          reason: "Nearby Interaction does not expose unrestricted raw radio samples."),
        capability("accelerometer", hardware: motion.isAccelerometerAvailable, api: true,
          measurement: motion.isAccelerometerAvailable, capabilityClass: "commonAndExposed", quality: 0.85),
        capability("gyroscope", hardware: motion.isGyroAvailable, api: true,
          measurement: motion.isGyroAvailable, capabilityClass: "commonAndExposed", quality: 0.85),
        capability("magnetometer", hardware: motion.isMagnetometerAvailable, api: true,
          measurement: motion.isMagnetometerAvailable, capabilityClass: "commonAndExposed", quality: 0.65),
        capability("barometer", hardware: altimeter, api: true, measurement: altimeter,
          capabilityClass: "selectedDevices", quality: 0.60),
        capability("gnss", hardware: location, api: true, measurement: false,
          capabilityClass: "commonAndExposed", quality: 0.55,
          reason: "Measurement availability depends on runtime location authorization."),
        capability("microphone", hardware: microphone, api: true, measurement: false,
          capabilityClass: "commonAndExposed", quality: 0.50,
          reason: "Measurement availability depends on runtime microphone authorization."),
      ]
    ]
  }
}
