package com.trochez.body_finder

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import kotlin.math.max
import kotlin.math.pow

/**
 * Physical BLE RSSI measurement adapter.
 *
 * The connectable Body Finder advertisement is owned by BleSessionBridge so
 * communication does not depend on location authorization. This bridge only
 * scans that advertisement and converts RSSI into coarse physical range data.
 */
class BleRangingBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "body_finder/ble_ranging"
        private const val REQUEST_CODE = 6142
        private const val PATH_LOSS_EXPONENT = 2.2
        private const val FALLBACK_TX_POWER_DBM = -59
        private const val MIN_EMIT_INTERVAL_MS = 500L
        private val SERVICE_UUID = ParcelUuid(
            UUID.fromString("93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31"),
        )
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val bluetoothManager =
        activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

    private var pendingResult: MethodChannel.Result? = null
    private var pendingNodeId: String? = null
    private var localNodeId: String? = null
    private var scanning = false
    private val smoothedRssi = mutableMapOf<String, Double>()
    private val lastEmitMs = mutableMapOf<String, Long>()

    init {
        channel.setMethodCallHandler(::handleCall)
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val nodeId = call.argument<String>("nodeId")
                if (nodeId.isNullOrBlank()) {
                    result.error("invalid_node_id", "A nodeId is required for BLE ranging.", null)
                    return
                }
                startWithPermissions(nodeId, result)
            }
            "stop" -> {
                stop()
                result.success(mapOf("status" to "stopped"))
            }
            else -> result.notImplemented()
        }
    }

    private fun startWithPermissions(nodeId: String, result: MethodChannel.Result) {
        val missing = requiredPermissions().filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            pendingResult?.error(
                "permission_request_replaced",
                "A newer BLE ranging permission request replaced this request.",
                null,
            )
            pendingResult = result
            pendingNodeId = nodeId
            activity.requestPermissions(missing.toTypedArray(), REQUEST_CODE)
            return
        }
        result.success(startInternal(nodeId))
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult
        val nodeId = pendingNodeId
        pendingResult = null
        pendingNodeId = null

        if (result == null || nodeId == null) return true
        val denied = permissions.indices
            .filter { grantResults.getOrNull(it) != PackageManager.PERMISSION_GRANTED }
            .map { permissions[it] }
        if (denied.isNotEmpty()) {
            result.success(
                mapOf(
                    "status" to "permissionDenied",
                    "denied" to denied,
                ),
            )
            return true
        }
        result.success(startInternal(nodeId))
        return true
    }

    private fun startInternal(nodeId: String): Map<String, Any> {
        stop()
        val adapter = bluetoothManager.adapter
            ?: return mapOf("status" to "unavailable", "reason" to "No Bluetooth adapter")
        if (!adapter.isEnabled) {
            return mapOf("status" to "bluetoothOff", "reason" to "Bluetooth is disabled")
        }
        val scanner = adapter.bluetoothLeScanner
            ?: return mapOf("status" to "unavailable", "reason" to "BLE scanner unavailable")
        if (!nodeId.lowercase().matches(Regex("[0-9a-f]{16}"))) {
            return mapOf("status" to "invalidNodeId", "reason" to "nodeId must contain 16 hex characters")
        }

        localNodeId = nodeId.lowercase()
        smoothedRssi.clear()
        lastEmitMs.clear()

        return try {
            scanner.startScan(
                null,
                ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .build(),
                scanCallback,
            )
            scanning = true
            mapOf("status" to "started", "source" to "bleRssi")
        } catch (error: SecurityException) {
            stop()
            mapOf("status" to "permissionDenied", "reason" to (error.message ?: "Bluetooth permission denied"))
        } catch (error: Exception) {
            stop()
            mapOf("status" to "failed", "reason" to (error.message ?: error.javaClass.simpleName))
        }
    }

    fun stop() {
        val adapter = bluetoothManager.adapter
        try {
            if (scanning) adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (_: SecurityException) {
        }
        scanning = false
        localNodeId = null
        smoothedRssi.clear()
        lastEmitMs.clear()
    }

    fun dispose() {
        stop()
        pendingResult?.error("disposed", "BLE ranging bridge disposed.", null)
        pendingResult = null
        pendingNodeId = null
        channel.setMethodCallHandler(null)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val data = result.scanRecord?.getServiceData(SERVICE_UUID) ?: return
            // The first eight bytes are the persistent node ID. Newer Body
            // Finder advertisements may append freshness bytes so BlueZ does
            // not reuse stale ServiceData after a session restart.
            if (data.size < 8) return
            val peerNodeId = data.take(8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (peerNodeId == localNodeId) return

            val previous = smoothedRssi[peerNodeId]
            val filteredRssi = if (previous == null) {
                result.rssi.toDouble()
            } else {
                previous * 0.72 + result.rssi * 0.28
            }
            smoothedRssi[peerNodeId] = filteredRssi

            val txPower = result.scanRecord?.txPowerLevel
                ?.takeIf { it in -100..20 }
                ?: FALLBACK_TX_POWER_DBM
            val distance = 10.0.pow((txPower - filteredRssi) / (10.0 * PATH_LOSS_EXPONENT))
                .coerceIn(0.10, 50.0)
            val sigma = max(1.0, distance * 0.75)
            val now = System.currentTimeMillis()
            val last = lastEmitMs[peerNodeId] ?: 0L
            if (now - last < MIN_EMIT_INTERVAL_MS) return
            lastEmitMs[peerNodeId] = now

            activity.runOnUiThread {
                channel.invokeMethod(
                    "range",
                    mapOf(
                        "peerNodeId" to peerNodeId,
                        "distanceMeters" to distance,
                        "sigmaMeters" to sigma,
                        "rssiDbm" to filteredRssi,
                        "source" to "bleRssi",
                    ),
                )
            }
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            activity.runOnUiThread {
                channel.invokeMethod(
                    "status",
                    mapOf("status" to "scanFailed", "errorCode" to errorCode),
                )
            }
        }
    }

    private fun requiredPermissions(): List<String> {
        val permissions = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions += Manifest.permission.BLUETOOTH_SCAN
        }
        // RSSI is explicitly used as a coarse physical-ranging signal, so
        // location authorization remains tied to sensing, not BLE control.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            permissions += Manifest.permission.ACCESS_FINE_LOCATION
        }
        return permissions
    }
}
