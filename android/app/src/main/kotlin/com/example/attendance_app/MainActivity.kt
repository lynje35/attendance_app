package com.example.attendance_app

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private lateinit var apkUpdater: AndroidApkUpdater

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        apkUpdater = AndroidApkUpdater(this)
    }

    override fun onPostResume() {
        super.onPostResume()
        apkUpdater.onResume()
    }

    override fun onPause() {
        apkUpdater.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        apkUpdater.close()
        super.onDestroy()
    }
}
