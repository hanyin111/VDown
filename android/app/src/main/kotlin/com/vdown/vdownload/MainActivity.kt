package com.vdown.vdownload

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
                    } catch (e: Exception) {
                        post { result.error("INIT", e.message ?: e.toString(), null) }
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
                        } catch (e: Exception) {
                            post { result.error("FETCH", e.message ?: e.toString(), null) }
                        }
                    }
                }

                "download" -> {
                    val taskId = call.argument<String>("taskId")
                    val url = call.argument<String>("url")
                    val format = call.argument<String>("format")
                    val audioOnly = call.argument<Boolean>("audioOnly") ?: false
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
                        } catch (e: Exception) {
                            post { result.error("DOWNLOAD", e.message ?: e.toString(), null) }
                        }
                    }
                }

                "cancel" -> {
                    val taskId = call.argument<String>("taskId")
                    if (taskId != null) {
                        executor.execute { YoutubeDL.getInstance().destroyProcessById(taskId) }
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

    private fun post(action: () -> Unit) {
        mainHandler.post(action)
    }
}
