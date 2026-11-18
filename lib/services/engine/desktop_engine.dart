import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../utils/format_utils.dart';
import '../bilibili_live_service.dart';
import '../settings_service.dart';
import 'video_engine.dart';

enum _LiveStopMode { none, stopAndSave, split, cancel }

class _ResolvedStream {
  final String url;
  final Map<String, String> headers;

  _ResolvedStream({required this.url, required this.headers});
}

class _LiveSession {
  final DownloadSpec spec;
  _LiveStopMode stopMode = _LiveStopMode.none;
  Process? ffmpegProc;
  Process? ytdlpProc;
  bool usePipe = false;
  Completer<String?>? splitCompleter;

  _LiveSession(this.spec);
}

/// 桌面端引擎：调用 yt-dlp 与 FFmpeg 可执行文件。
/// 优先级：设置中手动指定的路径 > 程序目录 bin/ 下随附的二进制 > 系统 PATH。
class DesktopEngine extends VideoEngine {
  final SettingsService settings;
  final Map<String, Process> _processes = {};
  final Map<String, _LiveSession> _liveSessions = {};

  DesktopEngine(this.settings);

  @override
  bool get isBundled => _bundledYtdlp() != null;

  static String get _binDir =>
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}bin';

  static String? _bundledYtdlp() {
    final exe = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
    final path = '$_binDir${Platform.pathSeparator}$exe';
    return File(path).existsSync() ? path : null;
  }

  static String? _bundledFfmpegDir() {
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    return File('$_binDir${Platform.pathSeparator}$exe').existsSync()
        ? _binDir
        : null;
  }

  /// 实际调用的 yt-dlp 路径。
  String get _ytdlp {
    if (settings.ytdlpPath != 'yt-dlp') return settings.ytdlpPath;
    return _bundledYtdlp() ?? settings.ytdlpPath;
  }

  /// 实际使用的 FFmpeg 目录（null 表示交给 yt-dlp 从 PATH 找）。
  String? get _ffmpegDir {
    if (settings.ffmpegPath.isNotEmpty) return settings.ffmpegPath;
    return _bundledFfmpegDir();
  }

  /// 实际调用的 ffmpeg 可执行文件路径。
  String get _ffmpegExe {
    final exeName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final configured = settings.ffmpegPath.trim();
    if (configured.isNotEmpty) {
      if (File(configured).existsSync()) return configured;
      final inDir = '$configured${Platform.pathSeparator}$exeName';
      if (File(inDir).existsSync()) return inDir;
    }
    final bundled = _bundledFfmpegDir();
    if (bundled != null) {
      return '$bundled${Platform.pathSeparator}$exeName';
    }
    return exeName;
  }

  @override
  Future<String> version() async {
    try {
      final result = await Process.run(
        _ytdlp,
        ['--version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode == 0) return (result.stdout as String).trim();
      throw EngineException('yt-dlp 异常退出（${result.exitCode}）');
    } on ProcessException {
      throw EngineException('未找到 yt-dlp："${settings.ytdlpPath}"');
    }
  }

  @override
  Future<Map<String, dynamic>> fetchInfoJson(String url) async {
    if (BilibiliLiveService.isBilibiliLiveUrl(url)) {
      try {
        return await BilibiliLiveService.fetchLiveInfoJson(
          url,
          cookieHeader: settings.effectiveBiliCookieHeader,
          proxy: settings.proxy,
        );
      } catch (e) {
        final msg = e.toString();
        if (msg.contains('未开播')) {
          throw EngineException('该主播当前未开播，无法录制直播。');
        }
        // 直连失败时回退到 yt-dlp 解析
      }
    }

    final netArgs = await settings.resolveNetworkArgs();
    final args = <String>[
      '-J',
      '--no-playlist',
      '--no-warnings',
      ...netArgs,
      url,
    ];

    final ProcessResult result;
    try {
      result = await Process.run(
        _ytdlp,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException {
      throw EngineException(
        '找不到 yt-dlp（当前路径："${settings.ytdlpPath}"）。\n'
        '请先安装 yt-dlp 并加入 PATH，或在设置中指定其完整路径。',
      );
    }

    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw EngineException(
          '解析失败：${err.isEmpty ? '未知错误（退出码 ${result.exitCode}）' : err.split('\n').last}');
    }

    final json = jsonDecode(result.stdout as String);
    if (json is! Map<String, dynamic>) {
      throw EngineException('解析失败：yt-dlp 返回了无法识别的数据。');
    }
    return json;
  }

  @override
  Future<void> download(DownloadSpec spec, EngineOutputCallback onOutput) async {
    if (spec.isLive) {
      return _downloadLive(spec, onOutput);
    }

    final outputTemplate =
        '${spec.outputDir}${Platform.pathSeparator}%(title)s.%(ext)s';

    final netArgs = await settings.resolveNetworkArgs();
    final args = <String>[
      '--newline',
      '--no-playlist',
      '--no-warnings',
      '--continue',
      '-o', outputTemplate,
      ...netArgs,
      if (_ffmpegDir != null) ...[
        '--ffmpeg-location', _ffmpegDir!,
      ],
      if (spec.audioOnly) ...[
        '-f', spec.formatSelector,
        '-x',
        '--audio-format', 'mp3',
      ] else ...[
        '-f', spec.formatSelector,
        '--merge-output-format', 'mp4',
      ],
      if (spec.withSubtitles) ...[
        '--write-subs',
        '--sub-langs', 'all,-danmaku',
        '--convert-subs', 'srt',
      ],
      spec.url,
    ];

    final Process process;
    try {
      process = await Process.start(_ytdlp, args);
    } on ProcessException {
      throw EngineException('无法启动 yt-dlp，请检查设置中的引擎路径。');
    }

    _processes[spec.taskId] = process;
    final stderrLines = <String>[];

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => onOutput(null, null, line));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add);

    final exitCode = await process.exitCode;
    _processes.remove(spec.taskId);

    if (exitCode != 0) {
      final err = stderrLines.isEmpty ? '' : stderrLines.last;
      throw EngineException(
          err.isEmpty ? '下载失败（退出码 $exitCode）' : err);
    }
  }

  /// 实时录制直播流（YouTube / Bilibili / 其他），写入碎片化 MP4（或 MP3），
  /// 支持在任意时刻停止或断点切分并封装为标准 faststart 可播放视频。
  Future<void> _downloadLive(
      DownloadSpec spec, EngineOutputCallback onOutput) async {
    // 验证 FFmpeg 可用
    try {
      final ver = await Process.run(_ffmpegExe, ['-version']);
      if (ver.exitCode != 0) {
        throw EngineException('FFmpeg 不可用，直播录制需要 FFmpeg。');
      }
    } on ProcessException {
      throw EngineException(
        '未找到 FFmpeg（当前路径："$_ffmpegExe"）。\n'
        '直播实时录制与断点保存需要 FFmpeg，请安装或在设置中指定 FFmpeg 路径。',
      );
    }

    final session = _LiveSession(spec);
    _liveSessions[spec.taskId] = session;

    final safeTitle = _sanitizeFilename(spec.title ?? 'live_recording');
    final stamp = _formatTimestamp(DateTime.now());
    final ext = spec.audioOnly ? 'mp3' : 'mp4';
    final isBiliLive = BilibiliLiveService.isBilibiliLiveUrl(spec.url);
    final usePipe = !isBiliLive && (spec.liveFromStart || _isSocksProxy(settings.proxy));
    session.usePipe = usePipe;

    var segmentIndex = 1;
    final startClock = DateTime.now();

    try {
      while (true) {
        session.stopMode = _LiveStopMode.none;

        int? remainingSec;
        if (spec.maxDurationSeconds != null) {
          final elapsed = DateTime.now().difference(startClock).inSeconds;
          remainingSec = spec.maxDurationSeconds! - elapsed;
          if (remainingSec <= 0) break;
        }

        final suffix = segmentIndex == 1 ? '' : '_part${segmentIndex.toString().padLeft(2, '0')}';
        final finalPath =
            '${spec.outputDir}${Platform.pathSeparator}${safeTitle}_live_$stamp$suffix.$ext';
        final partPath = '$finalPath.part';

        final ffmpegArgs = <String>[];
        final env = Map<String, String>.from(Platform.environment);

        if (usePipe) {
          // 通过 yt-dlp 管道输出到 ffmpeg（支持 --live-from-start 与 socks 代理）
          final netArgs = await settings.resolveNetworkArgs();
          final ytdlpArgs = <String>[
            '--no-playlist',
            '--no-warnings',
            '--hls-use-mpegts',
            if (spec.liveFromStart) '--live-from-start',
            '-f', spec.formatSelector,
            ...netArgs,
            '-o', '-',
            spec.url,
          ];
          final ytdlpProc = await Process.start(_ytdlp, ytdlpArgs);
          session.ytdlpProc = ytdlpProc;
          // 排空 stderr 避免缓冲区阻塞
          ytdlpProc.stderr.drain<void>();

          ffmpegArgs.addAll(['-i', 'pipe:0']);
        } else {
          // 解析最新直链与请求头（Referer / User-Agent / Cookie 等）
          final streams = await _resolveLiveStreams(spec);
          if (streams.isEmpty) {
            throw EngineException('未获取到可用的直播流地址，请确认直播正在进行中。');
          }
          if (settings.proxy.isNotEmpty) {
            env['http_proxy'] = settings.proxy;
            env['https_proxy'] = settings.proxy;
            env['HTTP_PROXY'] = settings.proxy;
            env['HTTPS_PROXY'] = settings.proxy;
          }
          for (final s in streams) {
            if (s.url.startsWith('http://') || s.url.startsWith('https://')) {
              if (s.headers.isNotEmpty) {
                final headerText = s.headers.entries
                    .map((e) => '${e.key}: ${e.value}')
                    .join('\r\n');
                ffmpegArgs.addAll(['-headers', '$headerText\r\n']);
              }
              ffmpegArgs.addAll([
                '-reconnect', '1',
                '-reconnect_streamed', '1',
                '-reconnect_delay_max', '5',
                '-rw_timeout', '15000000',
              ]);
            }
            ffmpegArgs.addAll(['-i', s.url]);
          }
          if (streams.length >= 2 && !spec.audioOnly) {
            ffmpegArgs.addAll(['-map', '0:v?', '-map', '1:a?']);
          } else if (spec.audioOnly) {
            ffmpegArgs.addAll(['-map', '0:a?']);
          } else {
            ffmpegArgs.addAll(['-map', '0:v?', '-map', '0:a?']);
          }
        }

        if (spec.audioOnly) {
          ffmpegArgs.addAll(['-vn', '-c:a', 'libmp3lame', '-q:a', '2', '-f', 'mp3']);
        } else {
          ffmpegArgs.addAll([
            '-c', 'copy',
            '-f', 'mp4',
            '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
          ]);
        }

        if (remainingSec != null) {
          ffmpegArgs.addAll(['-t', '$remainingSec']);
        }
        ffmpegArgs.addAll(['-progress', 'pipe:1', '-nostats', '-y', partPath]);

        final ffmpegProc = await Process.start(
          _ffmpegExe,
          ffmpegArgs,
          environment: env,
        );
        session.ffmpegProc = ffmpegProc;

        if (usePipe && session.ytdlpProc != null) {
          final yp = session.ytdlpProc!;
          unawaited(
            yp.stdout
                .pipe(ffmpegProc.stdin)
                .catchError((_) {}),
          );
        }

        final stderrLines = <String>[];
        ffmpegProc.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(stderrLines.add);

        var outTime = '00:00:00';
        var totalSizeBytes = 0;
        var bitrate = '';
        var speed = '';

        ffmpegProc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
          final eq = line.indexOf('=');
          if (eq <= 0) return;
          final k = line.substring(0, eq).trim();
          final v = line.substring(eq + 1).trim();
          switch (k) {
            case 'out_time':
              final dot = v.indexOf('.');
              outTime = dot > 0 ? v.substring(0, dot) : v;
              break;
            case 'total_size':
              totalSizeBytes = int.tryParse(v) ?? totalSizeBytes;
              break;
            case 'bitrate':
              bitrate = v == 'N/A' ? '' : v;
              break;
            case 'speed':
              speed = v == 'N/A' ? '' : v;
              break;
            case 'progress':
              final sizeText =
                  totalSizeBytes > 0 ? formatBytes(totalSizeBytes) : '';
              onOutput(
                null,
                null,
                '[live-progress] time=$outTime|size=$sizeText|bitrate=$bitrate|speed=$speed|seg=$segmentIndex',
              );
              break;
          }
        });

        final exitCode = await ffmpegProc.exitCode;
        session.ytdlpProc?.kill();
        session.ytdlpProc = null;
        session.ffmpegProc = null;

        final stopMode = session.stopMode;
        final partFile = File(partPath);
        final hasRecordedData =
            partFile.existsSync() && partFile.lengthSync() > 1024;

        if (stopMode == _LiveStopMode.cancel && !hasRecordedData) {
          if (partFile.existsSync()) {
            try {
              partFile.deleteSync();
            } catch (_) {}
          }
          throw EngineException('已取消直播录制');
        }

        if (hasRecordedData) {
          if (stopMode != _LiveStopMode.split) {
            onOutput(null, null, '[live-finalizing]');
          }
          final saved = await _finalizeLiveFile(
            partPath,
            finalPath,
            audioOnly: spec.audioOnly,
          );
          if (stopMode == _LiveStopMode.split) {
            onOutput(null, null, '[live-segment] $saved');
            session.splitCompleter?.complete(saved);
            session.splitCompleter = null;
            segmentIndex++;
            continue;
          } else {
            onOutput(null, null, '[live-saved] $saved');
            break;
          }
        }

        if (stopMode == _LiveStopMode.split) {
          session.splitCompleter?.complete(null);
          session.splitCompleter = null;
          segmentIndex++;
          continue;
        }

        if (stopMode == _LiveStopMode.stopAndSave) {
          throw EngineException('尚未录得有效音视频数据，无法保存文件');
        }

        // 自然退出但未录到任何数据
        if (exitCode != 0) {
          final err = stderrLines.isEmpty ? '' : stderrLines.last;
          throw EngineException(
              err.isEmpty ? '直播录制失败（退出码 $exitCode）' : err);
        }
        break;
      }
    } finally {
      session.ytdlpProc?.kill();
      _liveSessions.remove(spec.taskId);
    }
  }

  Future<List<_ResolvedStream>> _resolveLiveStreams(DownloadSpec spec) async {
    if (BilibiliLiveService.isBilibiliLiveUrl(spec.url)) {
      try {
        final direct = await BilibiliLiveService.resolveStreamForSelector(
          spec.url,
          spec.formatSelector,
          cookieHeader: settings.effectiveBiliCookieHeader,
          proxy: settings.proxy,
        );
        if (direct != null) {
          return [_ResolvedStream(url: direct.url, headers: direct.headers)];
        }
      } catch (_) {
        // 回退到 yt-dlp 获取直播流
      }
    }

    final netArgs = await settings.resolveNetworkArgs();
    final args = <String>[
      '-j',
      '--no-playlist',
      '--no-warnings',
      '-f', spec.formatSelector,
      ...netArgs,
      spec.url,
    ];
    final result = await Process.run(
      _ytdlp,
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw EngineException(
          '获取直播流地址失败：${err.isEmpty ? '退出码 ${result.exitCode}' : err.split('\n').last}');
    }
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map<String, dynamic>) {
      throw EngineException('无法解析直播流元数据');
    }

    final rootHeaders = _extractHeaders(decoded['http_headers']);
    final reqFormats = decoded['requested_formats'];
    final out = <_ResolvedStream>[];

    if (reqFormats is List && reqFormats.isNotEmpty) {
      for (final item in reqFormats) {
        if (item is Map<String, dynamic>) {
          final u = item['url']?.toString() ?? '';
          if (u.isEmpty) continue;
          final headers = {
            ...rootHeaders,
            ..._extractHeaders(item['http_headers']),
          };
          out.add(_ResolvedStream(url: u, headers: headers));
        }
      }
    } else {
      final u = decoded['url']?.toString() ?? '';
      if (u.isNotEmpty) {
        out.add(_ResolvedStream(url: u, headers: rootHeaders));
      }
    }
    return out;
  }

  static Map<String, String> _extractHeaders(dynamic raw) {
    final map = <String, String>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        if (entry.key != null && entry.value != null) {
          map[entry.key.toString()] = entry.value.toString();
        }
      }
    }
    return map;
  }

  /// 将录制中的碎片化 MP4 重封装为标准 faststart MP4，确保所有播放器可拖动播放。
  Future<String> _finalizeLiveFile(
    String partPath,
    String finalPath, {
    required bool audioOnly,
  }) async {
    if (!audioOnly) {
      try {
        final res = await Process.run(_ffmpegExe, [
          '-y',
          '-i', partPath,
          '-c', 'copy',
          '-movflags', '+faststart',
          finalPath,
        ]);
        final outFile = File(finalPath);
        if (res.exitCode == 0 &&
            outFile.existsSync() &&
            outFile.lengthSync() > 0) {
          try {
            File(partPath).deleteSync();
          } catch (_) {}
          return finalPath;
        }
      } catch (_) {
        // faststart 重封装失败时退回直接使用碎片化 MP4（本身已可播放）
      }
    }
    final partFile = File(partPath);
    if (partFile.existsSync()) {
      await partFile.rename(finalPath);
    }
    return finalPath;
  }

  Future<void> _gracefulStopActiveProcess(_LiveSession session) async {
    if (session.usePipe) {
      session.ytdlpProc?.kill();
    } else {
      final ff = session.ffmpegProc;
      if (ff != null) {
        try {
          ff.stdin.writeln('q');
          await ff.stdin.flush();
        } catch (_) {}
      }
    }

    final ff = session.ffmpegProc;
    if (ff != null) {
      try {
        await ff.exitCode.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        ff.kill();
      }
    }
  }

  @override
  Future<void> stopAndSave(String taskId) async {
    final session = _liveSessions[taskId];
    if (session == null) {
      await cancel(taskId);
      return;
    }
    session.stopMode = _LiveStopMode.stopAndSave;
    await _gracefulStopActiveProcess(session);
  }

  @override
  Future<String?> splitCheckpoint(String taskId) async {
    final session = _liveSessions[taskId];
    if (session == null || session.stopMode != _LiveStopMode.none) return null;
    final completer = Completer<String?>();
    session.splitCompleter = completer;
    session.stopMode = _LiveStopMode.split;
    await _gracefulStopActiveProcess(session);
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
  }

  @override
  Future<void> cancel(String taskId) async {
    final session = _liveSessions[taskId];
    if (session != null) {
      session.stopMode = _LiveStopMode.cancel;
      await _gracefulStopActiveProcess(session);
      return;
    }
    _processes.remove(taskId)?.kill();
  }

  static bool _isSocksProxy(String proxy) =>
      proxy.trim().toLowerCase().startsWith('socks');

  static String _sanitizeFilename(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return 'live_recording';
    return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
  }

  static String _formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y$m${d}_$hh$mm$ss';
  }
}
