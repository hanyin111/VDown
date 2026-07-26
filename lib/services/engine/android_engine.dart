import 'dart:convert';

import 'package:flutter/services.dart';

import '../settings_service.dart';
import 'video_engine.dart';

/// Android 端引擎：通过平台通道桥接内置的 youtubedl-android（yt-dlp 移植）。
/// 引擎随 APK 打包，开箱即用，无需任何外部依赖。
class AndroidEngine implements VideoEngine {
  static const _channel = MethodChannel('vdown/engine');

  final SettingsService settings;
  final Map<String, EngineOutputCallback> _listeners = {};

  AndroidEngine(this.settings) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onProgress') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final taskId = args['taskId'] as String?;
        final cb = taskId == null ? null : _listeners[taskId];
        if (cb != null) {
          final raw = (args['progress'] as num?)?.toDouble() ?? -1;
          final etaSec = (args['eta'] as num?)?.toInt() ?? -1;
          cb(
            raw >= 0 ? (raw / 100).clamp(0.0, 1.0) : null,
            etaSec >= 0 ? _formatEta(etaSec) : null,
            args['line'] as String? ?? '',
          );
        }
      }
    });
  }

  @override
  bool get isBundled => true;

  static String _formatEta(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    final h = seconds ~/ 3600;
    return h > 0 ? '$h:${(seconds % 3600 ~/ 60).toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  @override
  Future<String> version() async {
    try {
      final v = await _channel.invokeMethod<String>('init');
      return v ?? 'unknown';
    } on PlatformException catch (e) {
      throw EngineException('内置引擎初始化失败：${e.message}');
    }
  }

  @override
  Future<Map<String, dynamic>> fetchInfoJson(String url) async {
    try {
      final out = await _channel.invokeMethod<String>('fetchInfo', {
        'url': url,
        'proxy': settings.proxy,
      });
      final json = jsonDecode(out ?? '');
      if (json is! Map<String, dynamic>) {
        throw EngineException('解析失败：引擎返回了无法识别的数据。');
      }
      return json;
    } on PlatformException catch (e) {
      throw EngineException('解析失败：${_lastLine(e.message)}');
    } on FormatException {
      throw EngineException('解析失败：引擎返回了无法识别的数据。');
    }
  }

  @override
  Future<void> download(DownloadSpec spec, EngineOutputCallback onOutput) async {
    _listeners[spec.taskId] = onOutput;
    try {
      await _channel.invokeMethod('download', {
        'taskId': spec.taskId,
        'url': spec.url,
        'format': spec.formatSelector,
        'audioOnly': spec.audioOnly,
        'outputDir': spec.outputDir,
        'proxy': settings.proxy,
      });
    } on PlatformException catch (e) {
      throw EngineException(_lastLine(e.message));
    } finally {
      _listeners.remove(spec.taskId);
    }
  }

  @override
  Future<void> cancel(String taskId) async {
    await _channel.invokeMethod('cancel', {'taskId': taskId});
  }

  static String _lastLine(String? message) {
    final m = (message ?? '').trim();
    if (m.isEmpty) return '未知错误';
    final lines = m.split('\n').where((l) => l.trim().isNotEmpty).toList();
    // yt-dlp 的报错通常在最后一行 "ERROR: ..."
    return lines.lastWhere((l) => l.contains('ERROR'), orElse: () => lines.last);
  }
}
