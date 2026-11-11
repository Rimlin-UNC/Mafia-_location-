package com.example.mafia_offline

import android.app.Activity
import android.content.Intent
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Кроме запуска Flutter, активность умеет одно: подключить телефон игрока
 * к Wi-Fi ведущего по данным из «единого кода» (канал `mafia_offline/wifi`).
 *
 * Используется системное окно «Сохранить сеть?» (Android 11+). Сеть добавляет
 * не приложение, а система, и только после согласия владельца телефона, —
 * поэтому новых разрешений в манифесте нет. Для одной сети системные
 * настройки после сохранения сами вызывают подключение.
 */
class MainActivity : FlutterActivity() {
    private var pendingWifi: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "addNetwork" -> addNetwork(
                        call.argument<String>("ssid") ?: "",
                        call.argument<String>("password") ?: "",
                        call.argument<String>("security") ?: "wpa",
                        call.argument<Boolean>("hidden") ?: false,
                        result
                    )
                    "openWifiSettings" -> result.success(openWifiSettings())
                    else -> result.notImplemented()
                }
            }
    }

    private fun addNetwork(
        ssid: String,
        password: String,
        security: String,
        hidden: Boolean,
        result: MethodChannel.Result
    ) {
        // Окно сохранения сети появилось в Android 11.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success("unsupported")
            return
        }
        if (ssid.isEmpty() || (security != "wpa" && security != "open")) {
            result.success("unsupported")
            return
        }
        if (pendingWifi != null) {
            result.success("failed")
            return
        }
        try {
            val builder = WifiNetworkSuggestion.Builder()
                .setSsid(ssid)
                .setIsHiddenSsid(hidden)
            if (security == "wpa") {
                // Бросает исключение, если пароль не годится для WPA
                // (короче 8 символов или не ASCII) — тогда вернём "failed".
                builder.setWpa2Passphrase(password)
            }
            // Ровно одна сеть: только в этом случае системное окно после
            // сохранения само подключает телефон к ней.
            val networks = arrayListOf(builder.build())
            val intent = Intent(Settings.ACTION_WIFI_ADD_NETWORKS)
                .putParcelableArrayListExtra(Settings.EXTRA_WIFI_NETWORK_LIST, networks)
            pendingWifi = result
            startActivityForResult(intent, REQUEST_ADD_WIFI)
        } catch (e: Exception) {
            pendingWifi = null
            result.success("failed")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_ADD_WIFI) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingWifi ?: return
        pendingWifi = null

        if (resultCode != Activity.RESULT_OK) {
            result.success("cancelled")
            return
        }
        val codes = data?.getIntegerArrayListExtra(Settings.EXTRA_WIFI_NETWORK_RESULT_LIST)
        val code = if (codes != null && codes.isNotEmpty()) codes[0] else null
        result.success(
            when (code) {
                null, Settings.ADD_WIFI_RESULT_SUCCESS -> "saved"
                Settings.ADD_WIFI_RESULT_ALREADY_EXISTS -> "exists"
                else -> "failed"
            }
        )
    }

    private fun openWifiSettings(): Boolean {
        val intents = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Панель поверх приложения: игрок не уходит с экрана входа.
            intents.add(Intent(Settings.Panel.ACTION_WIFI))
        }
        intents.add(Intent(Settings.ACTION_WIFI_SETTINGS))
        for (intent in intents) {
            try {
                startActivity(intent)
                return true
            } catch (e: Exception) {
                // Пробуем следующий вариант.
            }
        }
        return false
    }

    companion object {
        private const val WIFI_CHANNEL = "mafia_offline/wifi"
        private const val REQUEST_ADD_WIFI = 4711
    }
}
