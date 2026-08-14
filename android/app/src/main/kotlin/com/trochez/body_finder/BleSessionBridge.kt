package com.trochez.body_finder

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.UUID

/**
 * BLE GATT endpoint for Body Finder session/control traffic.
 *
 * This bridge owns the connectable Body Finder advertisement and transports
 * already-encoded session chunks. It does not create range or anomaly
 * measurements. Physical BLE RSSI ranging is intentionally kept in
 * [BleRangingBridge], which only scans this advertisement.
 */
class BleSessionBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "body_finder/ble_session"
        private const val REQUEST_CODE = 6143
        private val SERVICE_UUID = UUID.fromString("93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31")
        private val SERVICE_PARCEL_UUID = ParcelUuid(SERVICE_UUID)
        private val SESSION_CHARACTERISTIC_UUID =
            UUID.fromString("93f3b61f-5e3c-4a73-9d10-8fbc5cf4de31")
        private val CLIENT_CONFIGURATION_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private data class PendingNotification(
        val device: BluetoothDevice,
        val value: ByteArray,
    )

    private val channel = MethodChannel(messenger, CHANNEL)
    private val bluetoothManager =
        activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val secureRandom = SecureRandom()

    private var gattServer: BluetoothGattServer? = null
    private var sessionCharacteristic: BluetoothGattCharacteristic? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingNodeId: String? = null
    private val connectedDevices = linkedSetOf<BluetoothDevice>()
    private val subscribedDevices = linkedSetOf<BluetoothDevice>()
    private val notificationQueue = ArrayDeque<PendingNotification>()
    private var notificationInFlight = false
    private var advertising = false
    private var advertisingReady = false
    private var gattServiceReady = false
    private var running = false

    init {
        channel.setMethodCallHandler(::handleCall)
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val nodeId = call.argument<String>("nodeId")
                if (nodeId.isNullOrBlank() || !nodeId.matches(Regex("[0-9a-fA-F]{16}"))) {
                    result.error("invalidNodeId", "nodeId must contain exactly 16 hex characters", null)
                    return
                }
                startWithPermissions(nodeId, result)
            }
            "sendChunk" -> {
                val raw = call.argument<List<Int>>("bytes")
                if (raw == null || raw.isEmpty() || raw.any { it !in 0..255 }) {
                    result.error("invalidChunk", "A non-empty byte chunk is required", null)
                    return
                }
                sendChunk(raw.map { it.toByte() }.toByteArray())
                result.success(null)
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
                "A newer BLE session permission request replaced this request.",
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
            result.success(mapOf("status" to "permissionDenied", "denied" to denied))
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
        val advertiser = adapter.bluetoothLeAdvertiser
            ?: return mapOf("status" to "unavailable", "reason" to "BLE advertising unavailable")
        val nodeBytes = hexNodeIdToBytes(nodeId)
            ?: return mapOf("status" to "invalidNodeId", "reason" to "nodeId must contain 16 hex characters")

        return try {
            val server = bluetoothManager.openGattServer(activity, callback)
                ?: return mapOf("status" to "failed", "reason" to "Could not open GATT server")
            val service = BluetoothGattService(
                SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY,
            )
            val characteristic = BluetoothGattCharacteristic(
                SESSION_CHARACTERISTIC_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            val cccd = BluetoothGattDescriptor(
                CLIENT_CONFIGURATION_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            )
            characteristic.addDescriptor(cccd)
            service.addCharacteristic(characteristic)

            gattServer = server
            sessionCharacteristic = characteristic
            running = server.addService(service)
            if (!running) {
                stop()
                return mapOf("status" to "failed", "reason" to "Could not register GATT service")
            }

            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .setTimeout(0)
                .build()

            // The persistent 8-byte node ID remains the first bytes. A ninth
            // per-session freshness byte forces BlueZ to observe a changed
            // ServiceData value after app/session restarts instead of reusing a
            // stale cached node-ID payload. It is diagnostic freshness only,
            // not an identity or security primitive.
            val serviceData = ByteArray(nodeBytes.size + 1)
            nodeBytes.copyInto(serviceData)
            serviceData[nodeBytes.size] = secureRandom.nextInt(256).toByte()

            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceData(SERVICE_PARCEL_UUID, serviceData)
                .build()
            advertiser.startAdvertising(settings, data, advertiseCallback)
            advertising = true

            mapOf(
                "status" to "started",
                "nodeId" to nodeId.lowercase(),
                "serviceUuid" to SERVICE_UUID.toString(),
                "characteristicUuid" to SESSION_CHARACTERISTIC_UUID.toString(),
            )
        } catch (error: SecurityException) {
            stop()
            mapOf("status" to "permissionDenied", "reason" to (error.message ?: "Bluetooth permission denied"))
        } catch (error: Exception) {
            stop()
            mapOf("status" to "failed", "reason" to (error.message ?: error.javaClass.simpleName))
        }
    }

    private fun sendChunk(value: ByteArray) {
        if (value.isEmpty()) return
        for (device in subscribedDevices.toList()) {
            notificationQueue.addLast(
                PendingNotification(device, value.copyOf()),
            )
        }
        drainNotificationQueue()
    }

    private fun drainNotificationQueue() {
        if (notificationInFlight) return
        val server = gattServer ?: return
        val characteristic = sessionCharacteristic ?: return

        while (notificationQueue.isNotEmpty()) {
            val pending = notificationQueue.removeFirst()
            if (!subscribedDevices.contains(pending.device)) continue
            val initiated = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    server.notifyCharacteristicChanged(
                        pending.device,
                        characteristic,
                        false,
                        pending.value,
                    ) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.value = pending.value
                    @Suppress("DEPRECATION")
                    server.notifyCharacteristicChanged(
                        pending.device,
                        characteristic,
                        false,
                    )
                }
            } catch (_: SecurityException) {
                false
            } catch (_: IllegalArgumentException) {
                false
            }

            if (initiated) {
                notificationInFlight = true
                return
            }
        }
    }

    fun stop() {
        val adapter = bluetoothManager.adapter
        if (advertising) {
            try {
                adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            } catch (_: SecurityException) {
            }
        }
        advertising = false
        advertisingReady = false
        gattServiceReady = false

        notificationQueue.clear()
        notificationInFlight = false
        val server = gattServer
        gattServer = null
        sessionCharacteristic = null
        running = false
        connectedDevices.clear()
        subscribedDevices.clear()
        try {
            server?.clearServices()
            server?.close()
        } catch (_: SecurityException) {
        }
    }

    fun dispose() {
        stop()
        pendingResult?.error("disposed", "BLE session bridge disposed.", null)
        pendingResult = null
        pendingNodeId = null
        channel.setMethodCallHandler(null)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advertisingReady = true
            emitEndpointReadiness()
        }

        override fun onStartFailure(errorCode: Int) {
            advertising = false
            advertisingReady = false
            activity.runOnUiThread {
                channel.invokeMethod(
                    "status",
                    mapOf("status" to "advertiseFailed", "errorCode" to errorCode),
                )
            }
        }
    }

    private fun emitEndpointReadiness() {
        val status = when {
            gattServiceReady && advertisingReady -> "readyForPeer"
            gattServiceReady -> "gattReady"
            advertisingReady -> "advertisingReady"
            else -> return
        }
        activity.runOnUiThread {
            channel.invokeMethod(
                "status",
                mapOf(
                    "status" to status,
                    "gattReady" to gattServiceReady,
                    "advertisingReady" to advertisingReady,
                ),
            )
        }
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (service.uuid != SERVICE_UUID) return
            gattServiceReady = status == BluetoothGatt.GATT_SUCCESS
            if (gattServiceReady) {
                emitEndpointReadiness()
            } else {
                activity.runOnUiThread {
                    channel.invokeMethod(
                        "status",
                        mapOf(
                            "status" to "serviceAddFailed",
                            "gattStatus" to status,
                        ),
                    )
                }
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevices.add(device)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectedDevices.remove(device)
                subscribedDevices.remove(device)
                notificationQueue.removeIf { it.device == device }
                if (notificationInFlight) {
                    // A disconnect can prevent onNotificationSent from arriving.
                    // Release the queue so other peers are not permanently blocked.
                    notificationInFlight = false
                    drainNotificationQueue()
                }
            }
            activity.runOnUiThread {
                channel.invokeMethod(
                    "status",
                    mapOf(
                        "status" to if (newState == BluetoothProfile.STATE_CONNECTED) "peerConnected" else "peerDisconnected",
                        "sourceKey" to device.address,
                        "connectedPeers" to connectedDevices.size,
                        "gattStatus" to status,
                    ),
                )
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid != SESSION_CHARACTERISTIC_UUID || preparedWrite || offset != 0) {
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                }
                return
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
            }
            activity.runOnUiThread {
                channel.invokeMethod(
                    "chunk",
                    mapOf(
                        "sourceKey" to device.address,
                        "bytes" to value.map { it.toInt() and 0xff },
                    ),
                )
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (descriptor.uuid != CLIENT_CONFIGURATION_UUID || preparedWrite || offset != 0) {
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                }
                return
            }
            val enabled = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
            if (enabled) subscribedDevices.add(device) else subscribedDevices.remove(device)
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
            }
            if (enabled) drainNotificationQueue()
            activity.runOnUiThread {
                channel.invokeMethod(
                    "status",
                    mapOf(
                        "status" to if (enabled) "peerSubscribed" else "peerUnsubscribed",
                        "sourceKey" to device.address,
                        "subscribedPeers" to subscribedDevices.size,
                    ),
                )
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            notificationInFlight = false
            if (status != BluetoothGatt.GATT_SUCCESS) {
                activity.runOnUiThread {
                    channel.invokeMethod(
                        "status",
                        mapOf(
                            "status" to "notificationFailed",
                            "sourceKey" to device.address,
                            "gattStatus" to status,
                        ),
                    )
                }
            }
            drainNotificationQueue()
        }
    }

    private fun requiredPermissions(): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return emptyList()
        return listOf(
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE,
        )
    }

    private fun hexNodeIdToBytes(nodeId: String): ByteArray? {
        val value = nodeId.lowercase().take(16)
        if (!value.matches(Regex("[0-9a-f]{16}"))) return null
        return ByteArray(8) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }
}
