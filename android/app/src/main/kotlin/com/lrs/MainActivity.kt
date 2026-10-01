package com.lrs

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = TimewebTokenStore.get(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TimewebTokenStore.CHANNEL)
            .setMethodCallHandler { call, result -> store.handle(call, result) }
    }
}

