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
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

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

    // 直播录制任务状态管理：支持任意时刻停止保存（stop）与分段断点保存（split）
    private val liveStopModes = ConcurrentHashMap<String, String>()
    private val liveProcessIds = ConcurrentHashMap<String, String>()
    private val splitLatches = ConcurrentHashMap<String, Pair<CountDownLatch, AtomicReference<String?>>>()

    private val ffmpegTimeRe = Regex("""time=(\d+:\d+:\d+)""")
    private val ffmpegSizeRe = Regex("""size=\s*(\d+\S*)""")
    private val ffmpegBitrateRe = Regex("""bitrate=\s*(\S+)""")
    private val ffmpegSpeedRe = Regex("""speed=\s*(\S+)""")

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
                    val cookiesPath = call.argument<String>("cookiesPath")
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
                            if (!cookiesPath.isNullOrEmpty() && File(cookiesPath).exists()) {
                                req.addOption("--cookies", cookiesPath)
                            }
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
                    val cookiesPath = call.argument<String>("cookiesPath")
                    val isLive = call.argument<Boolean>("isLive") ?: false
                    val liveFromStart = call.argument<Boolean>("liveFromStart") ?: false
                    val maxDurationSeconds = call.argument<Int>("maxDurationSeconds")
                    val title = call.argument<String>("title") ?: "live_recording"

                    if (taskId == null || url == null || format == null || outputDir == null) {
                        result.error("ARG", "missing arguments", null)
                        return@setMethodCallHandler
                    }

                    if (isLive) {
                        executor.execute {
                            executeLiveRecording(
                                taskId = taskId,
                                url = url,
                                format = format,
                                audioOnly = audioOnly,
                                outputDir = outputDir,
                                proxy = proxy,
                                cookiesPath = cookiesPath,
                                liveFromStart = liveFromStart,
                                maxDurationSeconds = maxDurationSeconds,
                                title = title,
                                result = result,
                            )
                        }
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
                            if (!cookiesPath.isNullOrEmpty() && File(cookiesPath).exists()) {
                                req.addOption("--cookies", cookiesPath)
                            }

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

                "stopAndSave" -> {
                    val taskId = call.argument<String>("taskId")
                    if (taskId != null) {
                        liveStopModes[taskId] = "stop"
                        emitProgress(taskId, "[live-finalizing]")
                        val pid = liveProcessIds[taskId] ?: taskId
                        executor.execute {
                            try {
                                YoutubeDL.getInstance().destroyProcessById(pid)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                    result.success(null)
                }

                "splitCheckpoint" -> {
                    val taskId = call.argument<String>("taskId")
                    if (taskId == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val latch = CountDownLatch(1)
                    val ref = AtomicReference<String?>(null)
                    splitLatches[taskId] = Pair(latch, ref)
                    liveStopModes[taskId] = "split"
                    val pid = liveProcessIds[taskId] ?: taskId
                    executor.execute {
                        try {
                            YoutubeDL.getInstance().destroyProcessById(pid)
                        } catch (_: Throwable) {
                        }
                        try {
                            latch.await(15, TimeUnit.SECONDS)
                        } catch (_: InterruptedException) {
                        }
                        splitLatches.remove(taskId)
                        post { result.success(ref.get()) }
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
                        liveStopModes[taskId] = "cancel"
                        val pid = liveProcessIds[taskId] ?: taskId
                        executor.execute {
                            try {
                                YoutubeDL.getInstance().destroyProcessById(pid)
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

    private fun executeLiveRecording(
        taskId: String,
        url: String,
        format: String,
        audioOnly: Boolean,
        outputDir: String,
        proxy: String?,
        cookiesPath: String?,
        liveFromStart: Boolean,
        maxDurationSeconds: Int?,
        title: String,
        result: MethodChannel.Result,
    ) {
        try {
            ensureInit()
            File(outputDir).mkdirs()

            val safeTitle = sanitizeFilename(title)
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val ext = if (audioOnly) "mp3" else "mp4"
            val startMs = System.currentTimeMillis()
            var segmentIndex = 1

            while (true) {
                liveStopModes.remove(taskId)
                var remainingSec: Int? = null
                if (maxDurationSeconds != null && maxDurationSeconds > 0) {
                    val elapsedSec = ((System.currentTimeMillis() - startMs) / 1000).toInt()
                    remainingSec = maxDurationSeconds - elapsedSec
                    if (remainingSec <= 0) break
                }

                val suffix = if (segmentIndex == 1) "" else "_part${segmentIndex.toString().padStart(2, '0')}"
                val outFile = File(outputDir, "${safeTitle}_live_$stamp$suffix.$ext")
                val procId = "${taskId}_seg_$segmentIndex"
                liveProcessIds[taskId] = procId

                val req = YoutubeDLRequest(url)
                req.addOption("--no-playlist")
                req.addOption("--no-warnings")
                req.addOption("--no-mtime")
                req.addOption("--no-part")
                req.addOption("--hls-use-mpegts")
                if (liveFromStart) {
                    req.addOption("--live-from-start")
                }
                req.addOption("-f", format)
                req.addOption("--downloader", "ffmpeg")

                val durationArg = if (remainingSec != null) " -t $remainingSec" else ""
                if (audioOnly) {
                    req.addOption("--downloader-args", "ffmpeg_o:-vn -c:a libmp3lame -q:a 2 -f mp3$durationArg")
                } else {
                    req.addOption(
                        "--downloader-args",
                        "ffmpeg_o:-f mp4 -movflags +frag_keyframe+empty_moov+default_base_moof$durationArg",
                    )
                }
                req.addOption("-o", outFile.absolutePath)
                if (!proxy.isNullOrEmpty()) req.addOption("--proxy", proxy)
                if (!cookiesPath.isNullOrEmpty() && File(cookiesPath).exists()) {
                    req.addOption("--cookies", cookiesPath)
                }

                var executeError: Throwable? = null
                try {
                    YoutubeDL.getInstance().execute(req, procId) { progress, etaSeconds, line ->
                        val parsed = parseFfmpegLiveLine(line, outFile, segmentIndex)
                        post {
                            channel?.invokeMethod(
                                "onProgress",
                                mapOf(
                                    "taskId" to taskId,
                                    "progress" to progress.toDouble(),
                                    "eta" to etaSeconds,
                                    "line" to (parsed ?: line),
                                ),
                            )
                        }
                    }
                } catch (t: Throwable) {
                    executeError = t
                }

                val stopMode = liveStopModes[taskId]
                val hasData = outFile.exists() && outFile.length() > 1024

                if (stopMode == "cancel" && !hasData) {
                    outFile.delete()
                    post { result.error("CANCELED", "已取消直播录制", null) }
                    return
                }

                if (hasData) {
                    if (stopMode == "split") {
                        emitProgress(taskId, "[live-segment] ${outFile.absolutePath}")
                        splitLatches[taskId]?.let { (latch, ref) ->
                            ref.set(outFile.absolutePath)
                            latch.countDown()
                        }
                        segmentIndex++
                        continue
                    } else {
                        emitProgress(taskId, "[live-saved] ${outFile.absolutePath}")
                        post { result.success(null) }
                        return
                    }
                }

                if (stopMode == "split") {
                    splitLatches[taskId]?.let { (latch, ref) ->
                        ref.set(null)
                        latch.countDown()
                    }
                    segmentIndex++
                    continue
                }

                if (executeError != null) {
                    post { result.error("DOWNLOAD", describe(executeError), null) }
                    return
                }
                break
            }
            post { result.success(null) }
        } catch (e: Throwable) {
            post { result.error("DOWNLOAD", describe(e), null) }
        } finally {
            liveStopModes.remove(taskId)
            liveProcessIds.remove(taskId)
            splitLatches.remove(taskId)?.first?.countDown()
        }
    }

    private fun parseFfmpegLiveLine(line: String, outFile: File, seg: Int): String? {
        val tm = ffmpegTimeRe.find(line)?.groupValues?.getOrNull(1) ?: return null
        val sz = ffmpegSizeRe.find(line)?.groupValues?.getOrNull(1)
            ?: if (outFile.exists()) "${outFile.length() / (1024 * 1024)} MB" else ""
        val br = ffmpegBitrateRe.find(line)?.groupValues?.getOrNull(1) ?: ""
        val sp = ffmpegSpeedRe.find(line)?.groupValues?.getOrNull(1) ?: ""
        return "[live-progress] time=$tm|size=$sz|bitrate=$br|speed=$sp|seg=$seg"
    }

    private fun emitProgress(taskId: String, line: String) {
        post {
            channel?.invokeMethod(
                "onProgress",
                mapOf(
                    "taskId" to taskId,
                    "progress" to -1.0,
                    "eta" to -1,
                    "line" to line,
                ),
            )
        }
    }

    private fun sanitizeFilename(raw: String): String {
        val cleaned = raw.replace(Regex("""[\\/:*?"<>|\r\n]+"""), "_")
            .replace(Regex("""\s+"""), " ")
            .trim()
        if (cleaned.isEmpty()) return "live_recording"
        return if (cleaned.length > 80) cleaned.substring(0, 80) else cleaned
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
