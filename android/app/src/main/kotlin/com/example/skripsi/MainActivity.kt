package com.example.skripsi

import android.util.Log
import com.polar.androidcommunications.api.ble.model.DisInfo
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApiCallback
import com.polar.sdk.api.PolarBleApiDefaultImpl
import com.polar.sdk.api.model.EcgSample
import com.polar.sdk.api.model.FecgSample
import com.polar.sdk.api.model.PolarDeviceInfo
import com.polar.sdk.api.model.PolarEcgDataSample
import com.polar.sdk.api.model.PolarHealthThermometerData
import com.polar.sdk.api.model.PolarSensorSetting
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.io.RandomAccessFile

class MainActivity : FlutterActivity() {
    private val PERF_CHANNEL = "ecg_app/perf"
    private val POLAR_CHANNEL = "ecg_app/polar"
    private val POLAR_ECG_EVENT_CHANNEL = "ecg_app/polar_ecg_stream"
    private val TAG = "MainActivityPolar"
    private val TARGET_ECG_SAMPLE_RATE = 130
    private val SEARCH_TIMEOUT_MS = 15_000L

    private var lastAppCpu: Long = 0L
    private var lastTotalCpu: Long = 0L
    private val polarScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var polarApi: PolarBleApi? = null
    private var polarEventSink: EventChannel.EventSink? = null
    private var searchJob: Job? = null
    private var ecgJob: Job? = null
    private var connectedDeviceId: String? = null
    private var connectedDeviceName: String? = null
    private var isEcgStreaming = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        setupPolarSdk()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCpuUsage" -> {
                        try {
                            val value = readAppCpuUsagePercent()
                            result.success(value)
                        } catch (e: Exception) {
                            result.error("CPU_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, POLAR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startScanAndConnect" -> {
                        startScanAndConnect()
                        result.success(null)
                    }
                    "startEcgStream" -> {
                        startEcgStream()
                        result.success(null)
                    }
                    "stopEcgStream" -> {
                        stopEcgStream()
                        result.success(null)
                    }
                    "disconnect" -> {
                        disconnectPolar()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, POLAR_ECG_EVENT_CHANNEL)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        polarEventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        polarEventSink = null
                    }
                }
            )
    }

    private fun setupPolarSdk() {
        if (polarApi != null) return

        val api = PolarBleApiDefaultImpl.defaultImplementation(
            applicationContext,
            setOf(
                PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING,
                PolarBleApi.PolarBleSdkFeature.FEATURE_DEVICE_INFO,
                PolarBleApi.PolarBleSdkFeature.FEATURE_BATTERY_INFO
            )
        )
        api.setPolarFilter(true)
        api.setApiLogger { message -> Log.d(TAG, message) }
        api.setApiCallback(
            object : PolarBleApiCallback() {
                override fun blePowerStateChanged(powered: Boolean) {
                    sendStatus(if (powered) "bluetooth_on" else "bluetooth_off")
                }

                override fun deviceConnecting(polarDeviceInfo: PolarDeviceInfo) {
                    connectedDeviceId = polarDeviceInfo.deviceId
                    connectedDeviceName = polarDeviceInfo.name
                    sendStatus(
                        status = "connecting",
                        deviceId = polarDeviceInfo.deviceId,
                        deviceName = polarDeviceInfo.name
                    )
                }

                override fun deviceConnected(polarDeviceInfo: PolarDeviceInfo) {
                    connectedDeviceId = polarDeviceInfo.deviceId
                    connectedDeviceName = polarDeviceInfo.name
                    sendStatus(
                        status = "connected",
                        deviceId = polarDeviceInfo.deviceId,
                        deviceName = polarDeviceInfo.name
                    )

                    if (polarApi?.isFeatureReady(
                            polarDeviceInfo.deviceId,
                            PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING
                        ) == true
                    ) {
                        startEcgStream()
                    }
                }

                override fun deviceDisconnected(polarDeviceInfo: PolarDeviceInfo) {
                    stopEcgStream()
                    sendStatus(
                        status = "disconnected",
                        deviceId = polarDeviceInfo.deviceId,
                        deviceName = polarDeviceInfo.name
                    )
                    connectedDeviceId = null
                    connectedDeviceName = null
                }

                override fun bleSdkFeatureReady(
                    identifier: String,
                    feature: PolarBleApi.PolarBleSdkFeature
                ) {
                    if (feature == PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING) {
                        sendStatus(
                            status = "online_streaming_ready",
                            deviceId = identifier,
                            deviceName = connectedDeviceName
                        )
                        startEcgStream()
                    }
                }

                override fun batteryLevelReceived(identifier: String, level: Int) {
                    sendStatus(
                        status = "battery",
                        deviceId = identifier,
                        deviceName = connectedDeviceName,
                        extra = mapOf("batteryLevel" to level)
                    )
                }

                override fun disInformationReceived(identifier: String, disInfo: DisInfo) {}

                override fun htsNotificationReceived(
                    identifier: String,
                    data: PolarHealthThermometerData
                ) {}
            }
        )
        polarApi = api
    }

    private fun startScanAndConnect() {
        val api = polarApi ?: run {
            sendErrorStatus("Polar SDK belum siap")
            return
        }

        stopEcgStream()
        searchJob?.cancel()
        connectedDeviceId = null
        connectedDeviceName = null
        sendStatus("scanning")

        searchJob = polarScope.launch {
            try {
                withTimeout(SEARCH_TIMEOUT_MS) {
                    api.searchForDevice("Polar").collect { deviceInfo ->
                        val isH10 = deviceInfo.name.contains("H10", ignoreCase = true)
                        if (!isH10 || !deviceInfo.isConnectable) return@collect

                        connectedDeviceId = deviceInfo.deviceId
                        connectedDeviceName = deviceInfo.name
                        sendStatus(
                            status = "connecting",
                            deviceId = deviceInfo.deviceId,
                            deviceName = deviceInfo.name
                        )
                        api.connectToDevice(deviceInfo.deviceId)
                        searchJob?.cancel()
                    }
                }
            } catch (error: Throwable) {
                if (error !is kotlinx.coroutines.CancellationException) {
                    sendErrorStatus("Polar H10 tidak ditemukan atau gagal scan: ${error.message}")
                }
            }
        }
    }

    private fun startEcgStream() {
        val api = polarApi ?: run {
            sendErrorStatus("Polar SDK belum siap")
            return
        }
        val deviceId = connectedDeviceId ?: run {
            sendErrorStatus("Polar H10 belum tersambung")
            return
        }

        if (isEcgStreaming || ecgJob?.isActive == true) return

        ecgJob = polarScope.launch {
            try {
                sendStatus(
                    status = "ecg_starting",
                    deviceId = deviceId,
                    deviceName = connectedDeviceName
                )
                val settings = api.requestStreamSettings(
                    deviceId,
                    PolarBleApi.PolarDeviceDataType.ECG
                )
                val selectedSettings = settings.maxSettings()
                val sampleRate = selectedSettings.settings[PolarSensorSetting.SettingType.SAMPLE_RATE]
                    ?.firstOrNull() ?: TARGET_ECG_SAMPLE_RATE

                isEcgStreaming = true
                sendStatus(
                    status = "ecg_started",
                    deviceId = deviceId,
                    deviceName = connectedDeviceName,
                    extra = mapOf("sampleRate" to sampleRate)
                )

                api.startEcgStreaming(deviceId, selectedSettings).collect { ecgData ->
                    val samples = ecgData.samples.mapNotNull { sample ->
                        sampleToMillivolts(sample)
                    }

                    if (samples.isNotEmpty()) {
                        sendEcgSamples(samples, ecgData.samples.last().timeStamp, sampleRate)
                    }
                }
            } catch (error: Throwable) {
                isEcgStreaming = false
                if (error !is kotlinx.coroutines.CancellationException) {
                    sendErrorStatus("ECG stream gagal: ${error.message}")
                }
            }
        }
    }

    private fun stopEcgStream() {
        ecgJob?.cancel()
        ecgJob = null
        if (isEcgStreaming) {
            sendStatus(
                status = "ecg_stopped",
                deviceId = connectedDeviceId,
                deviceName = connectedDeviceName
            )
        }
        isEcgStreaming = false
    }

    private fun disconnectPolar() {
        stopEcgStream()
        searchJob?.cancel()
        searchJob = null

        val deviceId = connectedDeviceId
        if (deviceId != null) {
            try {
                polarApi?.disconnectFromDevice(deviceId)
            } catch (error: Throwable) {
                sendErrorStatus("Gagal disconnect Polar: ${error.message}")
            }
        }

        connectedDeviceId = null
        connectedDeviceName = null
        sendStatus("disconnected")
    }

    private fun sampleToMillivolts(sample: PolarEcgDataSample): Double? {
        return when (sample) {
            is EcgSample -> sample.voltage.toDouble() / 1000.0
            is FecgSample -> sample.ecg.toDouble() / 1000.0
        }
    }

    private fun sendEcgSamples(samples: List<Double>, timestamp: Long, sampleRate: Int) {
        sendEvent(
            mapOf(
                "type" to "ecg",
                "samples" to samples,
                "timestamp" to timestamp,
                "sampleRate" to sampleRate
            )
        )
    }

    private fun sendStatus(
        status: String,
        deviceId: String? = connectedDeviceId,
        deviceName: String? = connectedDeviceName,
        extra: Map<String, Any?> = emptyMap()
    ) {
        val payload = mutableMapOf<String, Any?>(
            "type" to "status",
            "status" to status,
            "sampleRate" to TARGET_ECG_SAMPLE_RATE
        )
        if (deviceId != null) payload["deviceId"] = deviceId
        if (deviceName != null) payload["deviceName"] = deviceName
        payload.putAll(extra)
        sendEvent(payload)
    }

    private fun sendErrorStatus(message: String) {
        sendStatus(
            status = "error",
            extra = mapOf("message" to message)
        )
    }

    private fun sendEvent(payload: Map<String, Any?>) {
        runOnUiThread {
            polarEventSink?.success(payload)
        }
    }

    private fun readAppCpuUsagePercent(): Double {
        return try {
            val pid = android.os.Process.myPid()
            val processStatLine = RandomAccessFile("/proc/$pid/stat", "r").use {
                it.readLine()
            }

            val statTail = processStatLine.substringAfterLast(") ", "")
            val processParts = statTail.trim().split(Regex("\\s+"))
            if (processParts.size <= 14) {
                return 0.0
            }

            val utime = processParts[11].toLongOrNull() ?: 0L
            val stime = processParts[12].toLongOrNull() ?: 0L
            val cutime = processParts[13].toLongOrNull() ?: 0L
            val cstime = processParts[14].toLongOrNull() ?: 0L
            val appCpu = utime + stime + cutime + cstime

            val totalStatLine = RandomAccessFile("/proc/stat", "r").use {
                it.readLine()
            }

            val totalParts = totalStatLine.trim().split(Regex("\\s+")).drop(1)
            val totalCpu = totalParts.mapNotNull { it.toLongOrNull() }.sum()

            if (lastTotalCpu == 0L || lastAppCpu == 0L) {
                lastTotalCpu = totalCpu
                lastAppCpu = appCpu
                return 0.0
            }

            val appDelta = appCpu - lastAppCpu
            val totalDelta = totalCpu - lastTotalCpu

            lastAppCpu = appCpu
            lastTotalCpu = totalCpu

            if (totalDelta <= 0L || appDelta < 0L) return 0.0

            val coreCount = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
            (((appDelta.toDouble() / totalDelta.toDouble()) * coreCount) * 100.0)
                .coerceIn(0.0, 100.0)
        } catch (_: Exception) {
            return 0.0
        }
    }

    override fun onDestroy() {
        stopEcgStream()
        searchJob?.cancel()
        polarScope.cancel()
        polarApi?.shutDown()
        polarApi = null
        super.onDestroy()
    }
}
