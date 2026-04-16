package com.example.skripsi

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile

class MainActivity: FlutterActivity() {
    private val CHANNEL = "ecg_app/perf"
    private var lastAppCpu: Long = 0L
    private var lastTotalCpu: Long = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
        val totalCpu = readTotalCpuTime()
        val appCpu = readAppCpuTime()

        if (lastTotalCpu == 0L || lastAppCpu == 0L) {
            lastTotalCpu = totalCpu
            lastAppCpu = appCpu
            return 0.0
        }

        val totalDiff = totalCpu - lastTotalCpu
        val appDiff = appCpu - lastAppCpu

        lastTotalCpu = totalCpu
        lastAppCpu = appCpu

        if (totalDiff <= 0L) return 0.0

        return (appDiff.toDouble() / totalDiff.toDouble()) * 100.0
    }

    private fun readTotalCpuTime(): Long {
        RandomAccessFile("/proc/stat", "r").use { reader ->
            val line = reader.readLine()
            val toks = line.split("\\s+".toRegex()).drop(1)
            var sum = 0L
            for (token in toks) {
                sum += token.toLongOrNull() ?: 0L
            }
            return sum
        }
    }

    private fun readAppCpuTime(): Long {
        val pid = android.os.Process.myPid()
        RandomAccessFile("/proc/$pid/stat", "r").use { reader ->
            val line = reader.readLine()
            val toks = line.split("\\s+".toRegex())
            val utime = toks.getOrNull(13)?.toLongOrNull() ?: 0L
            val stime = toks.getOrNull(14)?.toLongOrNull() ?: 0L
            return utime + stime
        }
    }
}