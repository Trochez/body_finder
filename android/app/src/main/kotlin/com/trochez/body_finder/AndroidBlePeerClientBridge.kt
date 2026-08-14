package com.trochez.body_finder

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID

/**
 * Android BLE GATT client used only for Body Finder session/control traffic.
 *
 * Every Android node already exposes a GATT server through [BleSessionBridge].
 * This bridge adds the complementary client role so Android phones can form an
 * offline session without Linux, Wi-Fi, LAN, or Internet. For each peer pair,
 * the lexicographically smaller persistent node ID initiates the connection;
 * the larger node stays server-only for that pair. This avoids symmetric
 * connection races while still producing a full mesh for small rescue teams.
 *
 * This class never creates physical range or anomaly measurements. BLE RSSI
 * sensing remains isolated in [BleRangingBridge].
 */
class AndroidBlePeerClientBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "body_finder/ble_peer_client"
        private const val REQUEST_CODE = 6144
        private const val CONNECT_RETRY_MS = 2500L
        private val SERVICE_UUID = UUID.fromString("93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31")
        private val SERVICE_PARCEL_UUID = ParcelUuid(SERVICE_UUID)
        private val SESSION_CHARACTERISTIC_UUID =
            UUID.fromString("93f3b61f-5e3c-4a73-9d10-8fbc5cf4de31")
        private val CLIENT_CONFIGURATION_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private data class Peer(
        val nodeId: String,
        val device: BluetoothDevice,
        var gatt: BluetoothGatt? = null,
        var characteristic: BluetoothGattCharacteristic? = null,
        var ready: Boolean = false,
        var writeInFlight: Boolean = false,
        var lastConnectAttemptMs: Long = 0L,
        val writeQueue: ArrayDeque<ByteArray> = ArrayDeque(),
    )

    private val channel = MethodChannel(messenger, CHANNEL)
    private val adapter get() = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
    private var pendingResult: MethodChannel.Result? = null
    private var pendingNodeId: String? = null
    private var localNodeId: String? = null
    private var scanning = false
    private val peers = linkedMapOf<String, Peer>()

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
                startWithPermissions(nodeId.lowercase(), result)
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
                "A newer Android BLE peer permission request replaced this request.",
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
        val currentAdapter = adapter
            ?: return mapOf("status" to "unavailable", "reason" to "No Bluetooth adapter")
        if (!currentAdapter.isEnabled) {
            return mapOf("status" to "bluetoothOff", "reason" to "Bluetooth is disabled")
        }
        val scanner = currentAdapter.bluetoothLeScanner
            ?: return mapOf("status" to "unavailable", "reason" to "BLE scanner unavailable")

        localNodeId = nodeId
        return try {
            scanner.startScan(
                null,
                ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .build(),
                scanCallback,
            )
            scanning = true
            emitStatus("androidPeerScanStarted")
            mapOf("status" to "androidPeerScanStarted")
        } catch (error: SecurityException) {
            stop()
            mapOf("status" to "permissionDenied", "reason" to (error.message ?: "Bluetooth permission denied"))
        } catch (error: Exception) {
            stop()
            mapOf("status" to "failed", "reason" to (error.message ?: error.javaClass.simpleName))
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val data = result.scanRecord?.getServiceData(SERVICE_PARCEL_UUID) ?: return
            if (data.size < 8) return
            val peerNodeId = data.take(8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val local = localNodeId ?: return
            if (peerNodeId == local) return

            // Exactly one side initiates each pair. The peer with the larger
            // node ID will accept the inbound connection through BleSessionBridge.
            if (local >= peerNodeId) return

            val address = result.device.address
            val peer = peers[address] ?: Peer(peerNodeId, result.device).also {
                peers[address] = it
                emitStatus("androidPeerDiscovered", address, peerNodeId)
            }
            if (peer.ready || peer.gatt != null) return

            val now = System.currentTimeMillis()
            if (now - peer.lastConnectAttemptMs < CONNECT_RETRY_MS) return
            peer.lastConnectAttemptMs = now
            connect(peer)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            emitStatus("androidPeerScanFailed", extra = mapOf("errorCode" to errorCode))
        }
    }

    private fun connect(peer: Peer) {
        emitStatus("androidPeerConnecting", peer.device.address, peer.nodeId)
        try {
            val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                peer.device.connectGatt(activity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                peer.device.connectGatt(activity, false, gattCallback)
            }
            peer.gatt = gatt
            if (gatt == null) {
                emitStatus("androidPeerConnectStartFailed", peer.device.address, peer.nodeId)
            }
        } catch (error: SecurityException) {
            peer.gatt = null
            emitStatus(
                "androidPeerPermissionDenied",
                peer.device.address,
                peer.nodeId,
                mapOf("reason" to (error.message ?: "Bluetooth permission denied")),
            )
        } catch (error: Exception) {
            peer.gatt = null
            emitStatus(
                "androidPeerConnectStartFailed",
                peer.device.address,
                peer.nodeId,
                mapOf("reason" to (error.message ?: error.javaClass.simpleName)),
            )
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val peer = peers[gatt.device.address] ?: return
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                peer.gatt = gatt
                emitStatus("androidPeerConnected", gatt.device.address, peer.nodeId)
                try {
                    if (!gatt.discoverServices()) {
                        emitStatus("androidPeerServiceDiscoveryStartFailed", gatt.device.address, peer.nodeId)
                    }
                } catch (error: SecurityException) {
                    emitStatus("androidPeerPermissionDenied", gatt.device.address, peer.nodeId)
                }
                return
            }

            if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                peer.ready = false
                peer.characteristic = null
                peer.writeInFlight = false
                peer.writeQueue.clear()
                peer.gatt = null
                try {
                    gatt.close()
                } catch (_: Exception) {
                }
                emitStatus(
                    "androidPeerDisconnected",
                    gatt.device.address,
                    peer.nodeId,
                    mapOf("gattStatus" to status),
                )
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val peer = peers[gatt.device.address] ?: return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitStatus(
                    "androidPeerServiceDiscoveryFailed",
                    gatt.device.address,
                    peer.nodeId,
                    mapOf("gattStatus" to status),
                )
                return
            }
            val characteristic = gatt.getService(SERVICE_UUID)
                ?.getCharacteristic(SESSION_CHARACTERISTIC_UUID)
            if (characteristic == null) {
                emitStatus("androidPeerCharacteristicMissing", gatt.device.address, peer.nodeId)
                return
            }
            peer.characteristic = characteristic
            val descriptor = characteristic.getDescriptor(CLIENT_CONFIGURATION_UUID)
            if (descriptor == null) {
                emitStatus("androidPeerCccdMissing", gatt.device.address, peer.nodeId)
                return
            }

            try {
                if (!gatt.setCharacteristicNotification(characteristic, true)) {
                    emitStatus("androidPeerNotifyEnableFailed", gatt.device.address, peer.nodeId)
                    return
                }
                val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(
                        descriptor,
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE,
                    ) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(descriptor)
                }
                if (!started) {
                    emitStatus("androidPeerSubscribeStartFailed", gatt.device.address, peer.nodeId)
                } else {
                    emitStatus("androidPeerSubscribing", gatt.device.address, peer.nodeId)
                }
            } catch (error: SecurityException) {
                emitStatus("androidPeerPermissionDenied", gatt.device.address, peer.nodeId)
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != CLIENT_CONFIGURATION_UUID) return
            val peer = peers[gatt.device.address] ?: return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                peer.ready = true
                emitStatus("androidPeerSubscribed", gatt.device.address, peer.nodeId)
                drainWrites(peer)
            } else {
                emitStatus(
                    "androidPeerSubscribeFailed",
                    gatt.device.address,
                    peer.nodeId,
                    mapOf("gattStatus" to status),
                )
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            emitChunk(gatt.device.address, characteristic.value ?: return)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            emitChunk(gatt.device.address, value)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val peer = peers[gatt.device.address] ?: return
            peer.writeInFlight = false
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitStatus(
                    "androidPeerWriteFailed",
                    gatt.device.address,
                    peer.nodeId,
                    mapOf("gattStatus" to status),
                )
            }
            drainWrites(peer)
        }
    }

    private fun sendChunk(value: ByteArray) {
        if (value.isEmpty()) return
        for (peer in peers.values) {
            if (!peer.ready) continue
            peer.writeQueue.addLast(value.copyOf())
            drainWrites(peer)
        }
    }

    private fun drainWrites(peer: Peer) {
        if (!peer.ready || peer.writeInFlight) return
        val gatt = peer.gatt ?: return
        val characteristic = peer.characteristic ?: return
        val value = peer.writeQueue.pollFirst() ?: return

        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    value,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                characteristic.value = value
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
        } catch (_: SecurityException) {
            false
        }

        if (started) {
            peer.writeInFlight = true
        } else {
            emitStatus("androidPeerWriteStartFailed", peer.device.address, peer.nodeId)
            drainWrites(peer)
        }
    }

    private fun emitChunk(sourceKey: String, value: ByteArray) {
        if (value.isEmpty()) return
        activity.runOnUiThread {
            channel.invokeMethod(
                "chunk",
                mapOf(
                    "sourceKey" to sourceKey,
                    "bytes" to value.map { it.toInt() and 0xff },
                ),
            )
        }
    }

    private fun emitStatus(
        status: String,
        sourceKey: String? = null,
        peerNodeId: String? = null,
        extra: Map<String, Any> = emptyMap(),
    ) {
        val payload = linkedMapOf<String, Any>("status" to status)
        if (sourceKey != null) payload["sourceKey"] = sourceKey
        if (peerNodeId != null) payload["peerNodeId"] = peerNodeId
        payload.putAll(extra)
        activity.runOnUiThread {
            channel.invokeMethod("status", payload)
        }
    }

    fun stop() {
        val currentAdapter = adapter
        if (scanning) {
            try {
                currentAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
            } catch (_: SecurityException) {
            }
        }
        scanning = false
        localNodeId = null
        for (peer in peers.values) {
            val gatt = peer.gatt
            peer.gatt = null
            peer.ready = false
            peer.writeInFlight = false
            peer.writeQueue.clear()
            try {
                gatt?.disconnect()
                gatt?.close()
            } catch (_: SecurityException) {
            }
        }
        peers.clear()
    }

    fun dispose() {
        stop()
        pendingResult?.error("disposed", "Android BLE peer client disposed.", null)
        pendingResult = null
        pendingNodeId = null
        channel.setMethodCallHandler(null)
    }

    private fun requiredPermissions(): List<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            emptyList()
        }
    }
}
