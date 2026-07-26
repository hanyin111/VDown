package com.vdown.vdownload

import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

// 通过 MethodChannel 将内置 youtubedl-android 引擎暴露给 Flutter 侧。
// 注意统一捕获 Throwable：引擎初始化失败可能抛 Error（如 UnsatisfiedLinkError、
// NoClassDefFoundError），只捕 Exception 会导致应用闪退。
class MainActivity : FlutterActivity() {
    private val executor = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    @Volatile
    private var initialized = false
    private val initLock = Any()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vdown/engine")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> executor.execute {
                    try {
                        ensureInit()
                        val v = YoutubeDL.getInstance().version(applicationContext) ?: "unknown"
                        post { result.success(v) }
                    } catch (e: Throwable) {
                        post { result.error("INIT", describe(e), null) }
                    }
                }

                "fetchInfo" -> {
                    val url = call.argument<String>("url")
                    val proxy = call.argument<String>("proxy")
                    if (url == null) {
                        result.error("ARG", "url is required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            ensureInit()
                            val req = YoutubeDLRequest(url)
                            req.addOption("-J")
                            req.addOption("--no-playlist")
                            req.addOption("--no-warnings")
                            if (!proxy.isNullOrEmpty()) req.addOption("--proxy", proxy)
                            val resp = YoutubeDL.getInstance().execute(req)
                            post { result.success(resp.out) }
                        } catch (e: Throwable) {
                            post { result.error("FETCH", describe(e), null) }
                        }
                    }
                }

                "download" -> {
                    val taskId = call.argument<String>("taskId")
                    val url = call.argument<String>("url")
                    val format = call.argument<String>("format")
                    val audioOnly = call.argument<Boolean>("audioOnly") ?: false
                    val withSubtitles = call.argument<Boolean>("withSubtitles") ?: false
                    val outputDir = call.argument<String>("outputDir")
                    val proxy = call.argument<String>("proxy")
                    if (taskId == null || url == null || format == null || outputDir == null) {
                        result.error("ARG", "missing arguments", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            ensureInit()
                            File(outputDir).mkdirs()
                            val req = YoutubeDLRequest(url)
                            req.addOption("--no-playlist")
                            req.addOption("--no-warnings")
                            req.addOption("--continue")
                            req.addOption("--no-mtime")
                            req.addOption("-o", File(outputDir, "%(title)s.%(ext)s").absolutePath)
                            req.addOption("-f", format)
                            if (audioOnly) {
                                req.addOption("-x")
                                req.addOption("--audio-format", "mp3")
                            } else {
                                req.addOption("--merge-output-format", "mp4")
                            }
                            if (withSubtitles) {
                                req.addOption("--write-subs")
                                req.addOption("--sub-langs", "all,-danmaku")
                                req.addOption("--convert-subs", "srt")
                            }
                            if (!proxy.isNullOrEmpty()) req.addOption("--proxy", proxy)

                            YoutubeDL.getInstance().execute(req, taskId) { progress, etaSeconds, line ->
                                post {
                                    channel?.invokeMethod(
                                        "onProgress",
                                        mapOf(
                                            "taskId" to taskId,
                                            "progress" to progress.toDouble(),
                                            "eta" to etaSeconds,
                                            "line" to line,
                                        ),
                                    )
                                }
                            }
                            post { result.success(null) }
                        } catch (e: Throwable) {
                            post { result.error("DOWNLOAD", describe(e), null) }
                        }
                    }
                }

                "openDownloads" -> {
                    try {
                        val intent = Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("OPEN", describe(e), null)
                    }
                }

                "update" -> executor.execute {
                    try {
                        ensureInit()
                        val status = YoutubeDL.getInstance()
                            .updateYoutubeDL(application, YoutubeDL.UpdateChannel.STABLE)
                        val v = YoutubeDL.getInstance().version(applicationContext) ?: ""
                        post { result.success("${status?.name ?: "UNKNOWN"}|$v") }
                    } catch (e: Throwable) {
                        post { result.error("UPDATE", describe(e), null) }
                    }
                }

                "cancel" -> {
                    val taskId = call.argument<String>("taskId")
                    if (taskId != null) {
                        executor.execute {
                            try {
                                YoutubeDL.getInstance().destroyProcessById(taskId)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    // 首次调用时解压并初始化 Python/yt-dlp/FFmpeg 运行时（耗时数秒）。
    private fun ensureInit() {
        if (!initialized) {
            synchronized(initLock) {
                if (!initialized) {
                    YoutubeDL.getInstance().init(application)
                    FFmpeg.getInstance().init(application)
                    initialized = true
                }
            }
        }
    }

    // 带异常类名与根因的错误描述，便于在界面上定位问题。
    private fun describe(e: Throwable): String {
        val root = generateSequence(e) { it.cause }.last()
        val msg = e.message ?: ""
        val rootMsg = root.message ?: ""
        return buildString {
            append(e.javaClass.simpleName)
            if (msg.isNotEmpty()) append(": ").append(msg)
            if (root !== e) {
                append(" <- ").append(root.javaClass.simpleName)
                if (rootMsg.isNotEmpty()) append(": ").append(rootMsg)
            }
        }
    }

    private fun post(action: () -> Unit) {
        mainHandler.post(action)
    }
}
