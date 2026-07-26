import 'dart:convert';
import 'dart:io';

import '../settings_service.dart';
import 'video_engine.dart';

/// 桌面端引擎：调用本机 yt-dlp 可执行文件。
class DesktopEngine implements VideoEngine {
  final SettingsService settings;
  final Map<String, Process> _processes = {};

  DesktopEngine(this.settings);

  @override
  bool get isBundled => false;

  @override
  Future<String> version() async {
    try {
      final result = await Process.run(
        settings.ytdlpPath,
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
    final args = <String>[
      '-J',
      '--no-playlist',
      '--no-warnings',
      ...settings.commonNetworkArgs,
      url,
    ];

    final ProcessResult result;
    try {
      result = await Process.run(
        settings.ytdlpPath,
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
    final outputTemplate =
        '${spec.outputDir}${Platform.pathSeparator}%(title)s.%(ext)s';

    final args = <String>[
      '--newline',
      '--no-playlist',
      '--no-warnings',
      '--continue',
      '-o', outputTemplate,
      ...settings.commonNetworkArgs,
      if (settings.ffmpegPath.isNotEmpty) ...[
        '--ffmpeg-location', settings.ffmpegPath,
      ],
      if (spec.audioOnly) ...[
        '-f', spec.formatSelector,
        '-x',
        '--audio-format', 'mp3',
      ] else ...[
        '-f', spec.formatSelector,
        '--merge-output-format', 'mp4',
      ],
      spec.url,
    ];

    final Process process;
    try {
      process = await Process.start(settings.ytdlpPath, args);
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

  @override
  Future<void> cancel(String taskId) async {
    _processes.remove(taskId)?.kill();
  }
}
