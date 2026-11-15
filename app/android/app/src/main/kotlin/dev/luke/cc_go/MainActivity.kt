package dev.luke.cc_go

import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "cc_go/android"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(dev.luke.cc_go.voice.VoicePlugin())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openIgnoreBatteryOptimizations" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("no_activity", e.message, null)
                        }
                    }
                    "isBatteryExempt" -> {
                        val pm = getSystemService(PowerManager::class.java)
                        val exempt =
                            pm.isIgnoringBatteryOptimizations(packageName)
                        result.success(exempt)
                    }
                    // 直接弹系统豁免确认框（比设置列表少一步；无该 Action 的 ROM 回退列表页）。
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            try {
                                startActivity(
                                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                )
                                result.success(null)
                            } catch (e2: Exception) {
                                result.error("no_activity", e2.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
