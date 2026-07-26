import 'dart:io';

import '../settings_service.dart';
import 'android_engine.dart';
import 'desktop_engine.dart';

class EngineException implements Exception {
  final String message;
  EngineException(this.message);

  @override
  String toString() => message;
}

/// 一次下载所需的全部参数。
class DownloadSpec {
  final String taskId;
  final String url;
  final String formatSelector;
  final bool audioOnly;
  final String outputDir;

  const DownloadSpec({
    required this.taskId,
    required this.url,
    required this.formatSelector,
    required this.audioOnly,
    required this.outputDir,
  });
}

/// 引擎输出回调：[progress] 0-1（可能为 null，需从 [line] 自行解析）、
/// [etaText] 展示用剩余时间、[line] 引擎原始输出行。
typedef EngineOutputCallback = void Function(
    double? progress, String? etaText, String line);

/// 视频解析 / 下载引擎的平台无关接口。
/// 桌面端调用本机 yt-dlp 进程；Android 端桥接内置的 youtubedl-android。
abstract class VideoEngine {
  /// 引擎版本号；不可用时抛出 [EngineException]。
  Future<String> version();

  /// 解析视频信息，返回 yt-dlp -J 的 JSON。
  Future<Map<String, dynamic>> fetchInfoJson(String url);

  /// 执行下载，正常完成即成功；失败抛出 [EngineException]。
  Future<void> download(DownloadSpec spec, EngineOutputCallback onOutput);

  /// 取消正在进行的下载。
  Future<void> cancel(String taskId);

  /// 引擎是否内置（内置则无需在设置中配置路径）。
  bool get isBundled;
}

VideoEngine createEngine(SettingsService settings) {
  if (Platform.isAndroid) return AndroidEngine(settings);
  return DesktopEngine(settings);
}
