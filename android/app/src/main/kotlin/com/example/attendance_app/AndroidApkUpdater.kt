package com.example.attendance_app

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection

// Only Android uses this updater. Attendance state and Flutter networking are untouched.
class AndroidApkUpdater(private val activity: Activity) {
    companion object {
        private const val METADATA_URL = "https://kb-attendance-lynje-updates.web.app/latest.json"
        private const val MAX_APK_BYTES = 200L * 1024 * 1024
    }

    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var closed = false
    @Volatile private var connection: HttpsURLConnection? = null
    private var checking = false
    private var returningFromInstaller = false
    private var resumed = false
    private var awaitingPermission = false
    private var pendingApk: File? = null
    private var permissionDialog: AlertDialog? = null

    fun onResume() {
        resumed = true
        if (awaitingPermission) {
            awaitingPermission = false
            if (canInstall()) offerInstall()
            else {
                pendingApk = null
                toast("업데이트 설치를 취소했어요. 다음 앱 실행 때 다시 확인해요.")
            }
            return
        } else if (pendingApk != null) {
            offerInstall()
            return
        }
        if (returningFromInstaller) {
            returningFromInstaller = false
            return
        }
        if (!checking) {
            checking = true
            worker.execute { checkAndDownload() }
        }
    }

    fun onPause() { resumed = false }

    fun close() {
        closed = true
        connection?.disconnect()
        worker.shutdownNow()
        permissionDialog?.dismiss()
        permissionDialog = null
    }

    private fun ui(action: () -> Unit) {
        activity.runOnUiThread {
            if (!closed && !activity.isFinishing && !activity.isDestroyed) action()
        }
    }

    private fun toast(message: String) {
        if (resumed) Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
    }

    private fun checkAndDownload() {
        var downloading = false
        var temporary: File? = null
        try {
            val bytes = ByteArrayOutputStream()
            fetch(METADATA_URL, 32 * 1024L, 15_000L) { buffer, count ->
                bytes.write(buffer, 0, count)
            }
            val metadata = JSONObject(bytes.toString("UTF-8"))
            val latest = metadata.getLong("versionCode")
            val installed = activity.packageManager.getPackageInfo(activity.packageName, 0)
            if (latest <= versionCode(installed)) return
            require(latest in 1..Int.MAX_VALUE.toLong())
            val apkUrl = metadata.getString("apkUrl")
            require(URL(apkUrl).protocol == "https")
            val expectedHash = metadata.getString("sha256").lowercase()
            require(expectedHash.matches(Regex("[0-9a-f]{64}")))
            val expectedSize = metadata.getLong("sizeBytes")
            require(expectedSize in 1..MAX_APK_BYTES)

            val directory = File(activity.cacheDir, "apk_updates")
            require(directory.isDirectory || directory.mkdirs())
            val apk = File(directory, "update-$latest.apk")
            // A cancelled install can reuse the verified download on the next launch.
            if (!apk.exists() || !runCatching {
                    verifyApk(apk, latest, expectedSize, expectedHash)
                }.isSuccess) {
                downloading = true
                ui { toast("새 버전을 다운로드하고 있어요. 앱은 계속 사용할 수 있어요.") }
                require(directory.usableSpace > expectedSize + 20L * 1024 * 1024)
                val part = File.createTempFile("update-", ".part", directory)
                temporary = part
                part.outputStream().use { output ->
                    val count = fetch(apkUrl, expectedSize, 10 * 60_000L) { buffer, length ->
                        output.write(buffer, 0, length)
                    }
                    require(count == expectedSize)
                }
                verifyApk(part, latest, expectedSize, expectedHash)
                check(!closed)
                require(part.renameTo(apk))
                temporary = null
            }
            // Remove only obsolete updater files; never touch other application caches.
            directory.listFiles()?.filter { it != apk && it.name.matches(Regex("update-.*\\.(apk|part)")) }
                ?.forEach { it.delete() }
            ui {
                pendingApk = apk
                if (resumed) offerInstall()
            }
        } catch (error: Exception) {
            if (!closed) {
                Log.w("AttendanceUpdater", "Update check/download failed: ${error.javaClass.simpleName}")
                if (downloading) ui { toast("업데이트를 받지 못했어요. 다음 앱 실행 때 다시 시도해요.") }
            }
        } finally {
            temporary?.delete()
            ui { checking = false }
        }
    }

    private fun fetch(url: String, limit: Long, timeoutMs: Long,
                      consume: (ByteArray, Int) -> Unit): Long {
        var target = URL(url)
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        repeat(6) {
            check(!closed && SystemClock.elapsedRealtime() < deadline)
            require(target.protocol == "https" && target.userInfo == null)
            val request = target.openConnection() as HttpsURLConnection
            connection = request
            request.connectTimeout = 10_000
            request.readTimeout = 10_000
            request.useCaches = false
            request.instanceFollowRedirects = false
            request.setRequestProperty("Cache-Control", "no-cache")
            request.setRequestProperty("Accept-Encoding", "identity")
            try {
                val status = request.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    target = URL(target, requireNotNull(request.getHeaderField("Location")))
                } else {
                    require(status == 200)
                    require(request.contentLengthLong <= limit)
                    var total = 0L
                    request.inputStream.use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            check(!closed && SystemClock.elapsedRealtime() < deadline)
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= limit)
                            consume(buffer, count)
                        }
                    }
                    return total
                }
            } finally {
                request.disconnect()
                connection = null
            }
        }
        error("Too many redirects")
    }

    @Suppress("DEPRECATION")
    private fun verifyApk(file: File, version: Long, size: Long, hash: String) {
        require(file.length() == size)
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                check(!closed)
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        require(digest.digest().joinToString("") { "%02x".format(it) } == hash)
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
                    else PackageManager.GET_SIGNATURES
        val candidate = requireNotNull(activity.packageManager.getPackageArchiveInfo(file.path, flags))
        val current = activity.packageManager.getPackageInfo(activity.packageName, flags)
        require(candidate.packageName == activity.packageName)
        require(versionCode(candidate) == version && version > versionCode(current))
        require((candidate.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) <= Build.VERSION.SDK_INT)
        val currentSigners = signatures(current)
        require(currentSigners.isNotEmpty() && signatures(candidate) == currentSigners)
    }

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val signers = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners
                      else info.signatures
        return signers?.map { it.toCharsString() }?.toSet() ?: emptySet()
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun canInstall(): Boolean = Build.VERSION.SDK_INT < 26 ||
        activity.packageManager.canRequestPackageInstalls()

    private fun offerInstall() {
        if (!resumed || closed || permissionDialog != null) return
        val apk = pendingApk ?: return
        if (!canInstall()) {
            permissionDialog = AlertDialog.Builder(activity)
                .setTitle("업데이트 설치 허용")
                .setMessage("새 버전을 받았어요. 처음 한 번은 설정에서 ‘이 출처 허용’을 켠 뒤 앱으로 돌아와 주세요.")
                .setPositiveButton("설정 열기") { _, _ ->
                    try {
                        awaitingPermission = true
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")))
                    } catch (_: Exception) {
                        awaitingPermission = false
                        pendingApk = null
                        toast("설정을 열지 못했어요. 다음 앱 실행 때 다시 시도해요.")
                    }
                }
                .setNegativeButton("나중에") { _, _ -> pendingApk = null }
                .setOnCancelListener { pendingApk = null }
                .create().also { dialog ->
                    dialog.setOnDismissListener { permissionDialog = null }
                    dialog.show()
                }
            return
        }
        pendingApk = null // Returning from install/cancel must not open the installer again.
        try {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.apk_updates", apk)
            returningFromInstaller = true
            activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                clipData = ClipData.newRawUri("APK update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
        } catch (_: Exception) {
            returningFromInstaller = false
            toast("설치 화면을 열지 못했어요. 다음 앱 실행 때 다시 시도해요.")
        }
    }
}

class UpdateFileProvider : FileProvider()
