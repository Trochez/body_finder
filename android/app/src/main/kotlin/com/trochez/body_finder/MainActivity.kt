package com.trochez.body_finder

import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bleRangingBridge: BleRangingBridge? = null
    private var bleSessionBridge: BleSessionBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "body_finder/capabilities")
            .setMethodCallHandler { call, result ->
                if (call.method == "scanCapabilities") result.success(scanCapabilities())
                else result.notImplemented()
            }
        bleRangingBridge?.dispose()
        bleSessionBridge?.dispose()
        bleRangingBridge = BleRangingBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        bleSessionBridge = BleSessionBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (bleSessionBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        if (bleRangingBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        bleRangingBridge?.dispose()
        bleSessionBridge?.dispose()
        bleRangingBridge = null
        bleSessionBridge = null
        super.onDestroy()
    }

    private fun scanCapabilities(): Map<String, Any> {
        val pm = packageManager
        val sensors = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val bluetooth = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

        fun hasSensor(type: Int) = sensors.getDefaultSensor(type) != null
        fun capability(
            type: String,
            hardware: Boolean,
            api: Boolean,
            measurement: Boolean,
            capabilityClass: String,
            quality: Double,
            reason: String? = null,
        ) = mapOf(
            "sensorType" to type,
            "hardwareAvailable" to hardware,
            "apiAvailable" to api,
            "permissionState" to if (measurement) "notRequired" else "unknown",
            "measurementAvailable" to measurement,
            "capabilityClass" to capabilityClass,
            "estimatedQuality" to quality,
            "restrictionReason" to reason,
        )

        val ble = bluetooth != null && pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val wifi = pm.hasSystemFeature(PackageManager.FEATURE_WIFI)
        val wifiRtt = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            pm.hasSystemFeature(PackageManager.FEATURE_WIFI_RTT)
        val uwb = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            pm.hasSystemFeature("android.hardware.uwb")
        val gps = pm.hasSystemFeature(PackageManager.FEATURE_LOCATION_GPS)
        val microphone = pm.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)

        return mapOf(
            "platform" to "Android",
            "platformVersion" to Build.VERSION.RELEASE,
            "capabilities" to listOf(
                capability("bluetoothLowEnergy", ble, ble, false, "commonAndExposed", 0.55,
                    "Hardware/API detected; runtime scan permission is evaluated by the scanning adapter."),
                capability("wifi", wifi, wifi, wifi, "commonAndExposed", 0.45),
                capability("wifiRtt", wifiRtt, wifiRtt, false, "selectedDevices", 0.80,
                    "Ranging requires runtime permissions and a compatible peer/access point."),
                capability("wifiCsi", wifi, false, false, "hardwareApiRestricted", 0.0,
                    "No universal public raw CSI API is assumed."),
                capability("uwbRanging", uwb, uwb, false, "selectedDevices", 0.90,
                    "Ranging requires a compatible peer and session configuration."),
                capability("rawUwb", uwb, false, false, "hardwareApiRestricted", 0.0,
                    "Public ranging APIs do not expose unrestricted raw radio samples."),
                capability("accelerometer", hasSensor(Sensor.TYPE_ACCELEROMETER), true,
                    hasSensor(Sensor.TYPE_ACCELEROMETER), "commonAndExposed", 0.85),
                capability("gyroscope", hasSensor(Sensor.TYPE_GYROSCOPE), true,
                    hasSensor(Sensor.TYPE_GYROSCOPE), "commonAndExposed", 0.85),
                capability("magnetometer", hasSensor(Sensor.TYPE_MAGNETIC_FIELD), true,
                    hasSensor(Sensor.TYPE_MAGNETIC_FIELD), "commonAndExposed", 0.65),
                capability("barometer", hasSensor(Sensor.TYPE_PRESSURE), true,
                    hasSensor(Sensor.TYPE_PRESSURE), "selectedDevices", 0.60),
                capability("gnss", gps, true, false, "commonAndExposed", 0.55,
                    "Measurement availability depends on runtime location authorization."),
                capability("microphone", microphone, true, false, "commonAndExposed", 0.50,
                    "Measurement availability depends on runtime microphone authorization."),
            ),
        )
    }
}
