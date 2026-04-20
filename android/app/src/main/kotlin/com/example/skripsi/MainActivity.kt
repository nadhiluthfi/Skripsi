package com.example.skripsi

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile

class MainActivity : FlutterActivity() {
    private val PERF_CHANNEL = "ecg_app/perf"

    private var lastAppCpu: Long = 0L
    private var lastTotalCpu: Long = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
    }

    private fun readAppCpuUsagePercent(): Double {
        val pid = android.os.Process.myPid()

        val processStatLine = RandomAccessFile("/proc/$pid/stat", "r").use {
            it.readLine()
        }

        val processParts = processStatLine.trim().split(Regex("\\s+"))
        if (processParts.size <= 16) {
            return 0.0
        }

        val utime = processParts[13].toLongOrNull() ?: 0L
        val stime = processParts[14].toLongOrNull() ?: 0L
        val cutime = processParts[15].toLongOrNull() ?: 0L
        val cstime = processParts[16].toLongOrNull() ?: 0L
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

        if (totalDelta <= 0L) return 0.0

        return ((appDelta.toDouble() / totalDelta.toDouble()) * 100.0)
            .coerceAtLeast(0.0)
    }
}