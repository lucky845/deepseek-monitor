package com.deepseekmonitor.deepseek_monitor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The app publishes its snapshot, then rings this bell so the launcher
        // redraws. There is no data in the call: by the time it arrives the
        // numbers are already on disk.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "refresh" -> {
                        DeepSeekWidgetProvider.refresh(applicationContext)
                        // Same signal keeps the background refresher honest:
                        // connected means arm it, disconnected means stop it.
                        WidgetRefreshWorker.sync(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val CHANNEL = "deepseek_monitor/widget"
    }
}
