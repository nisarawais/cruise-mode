package com.navstudy.nav_study_sim

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nav_study/dnd")
            .setMethodCallHandler { call, result ->
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                when (call.method) {
                    "hasPermission" ->
                        result.success(nm.isNotificationPolicyAccessGranted)

                    "requestPermission" -> {
                        startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                        )
                        result.success(null)
                    }

                    "enable" -> {
                        if (nm.isNotificationPolicyAccessGranted) {
                            nm.setInterruptionFilter(
                                NotificationManager.INTERRUPTION_FILTER_NONE
                            )
                        }
                        result.success(null)
                    }

                    "disable" -> {
                        if (nm.isNotificationPolicyAccessGranted) {
                            nm.setInterruptionFilter(
                                NotificationManager.INTERRUPTION_FILTER_ALL
                            )
                        }
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
