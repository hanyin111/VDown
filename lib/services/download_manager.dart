import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import 'engine/video_engine.dart';
import 'settings_service.dart';

/// 下载队列：通过 [VideoEngine] 执行下载、解析进度输出、控制并发。
class DownloadManager extends ChangeNotifier {
  final SettingsService settings;
  final VideoEngine engine;
  final List<DownloadTask> tasks = [];

  DownloadManager(this.settings, this.engine);

  // 形如 "[download]  42.3% of ~ 120.45MiB at 3.21MiB/s ETA 00:35"
  static final _progressRe = RegExp(
    r'\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\w+)'
    r'(?:\s+at\s+([\d.]+\w+/s|Unknown speed))?'
    r'(?:\s+ETA\s+([\d:]+|Unknown))?',
  );
  static final _destRe = RegExp(r'\[download\] Destination: (.+)');
  static final _mergeRe = RegExp(r'\[Merger\] Merging formats into "(.+)"');

  int get _runningCount => tasks
      .where((t) =>
          t.status == TaskStatus.running || t.status == TaskStatus.merging)
      .length;

  void enqueue(DownloadTask task) {
    tasks.insert(0, task);
    notifyListeners();
    _pump();
  }

  /// 启动排队中的任务，直到达到并发上限。
  void _pump() {
    for (final task in tasks.reversed) {
      if (_runningCount >= settings.maxConcurrent) break;
      if (task.status == TaskStatus.queued) {
        _start(task);
      }
    }
  }

  Future<void> _start(DownloadTask task) async {
    task.status = TaskStatus.running;
    task.errorMessage = null;
    notifyListeners();

    try {
      await Directory(task.outputDir).create(recursive: true);
      await engine.download(
        DownloadSpec(
          taskId: task.id,
          url: task.url,
          formatSelector: task.formatSelector,
          audioOnly: task.audioOnly,
          outputDir: task.outputDir,
        ),
        (progress, eta, line) => _handleOutput(task, progress, eta, line),
      );
      if (task.status != TaskStatus.canceled) {
        task.status = TaskStatus.done;
        task.progress = 1;
        task.speed = null;
        task.eta = null;
      }
    } catch (e) {
      if (task.status != TaskStatus.canceled) {
        task.status = TaskStatus.error;
        task.errorMessage = e.toString();
      }
    }
    notifyListeners();
    _pump();
  }

  void _handleOutput(
      DownloadTask task, double? progress, String? eta, String line) {
    final match = _progressRe.firstMatch(line);
    if (match != null) {
      task.progress = (double.tryParse(match.group(1) ?? '') ?? 0) / 100;
      task.totalSize = match.group(2);
      final speed = match.group(3);
      final etaText = match.group(4);
      task.speed = (speed == null || speed == 'Unknown speed') ? null : speed;
      task.eta = (etaText == null || etaText == 'Unknown') ? null : etaText;
      notifyListeners();
      return;
    }
    // 行内无进度信息时使用引擎直接上报的数值（Android 端）。
    if (progress != null) {
      task.progress = progress;
      task.eta = eta;
      notifyListeners();
    }
    final dest = _destRe.firstMatch(line);
    if (dest != null) {
      task.outputFile = dest.group(1);
      return;
    }
    final merge = _mergeRe.firstMatch(line);
    if (merge != null) {
      task.status = TaskStatus.merging;
      task.outputFile = merge.group(1);
      notifyListeners();
    }
  }

  void cancel(DownloadTask task) {
    final wasQueued = task.status == TaskStatus.queued;
    task.status = TaskStatus.canceled;
    if (!wasQueued) engine.cancel(task.id);
    notifyListeners();
  }

  void retry(DownloadTask task) {
    if (task.isActive) return;
    task.status = TaskStatus.queued;
    task.progress = 0;
    task.errorMessage = null;
    notifyListeners();
    _pump();
  }

  void remove(DownloadTask task) {
    if (task.isActive) cancel(task);
    tasks.remove(task);
    notifyListeners();
  }

  void clearFinished() {
    tasks.removeWhere((t) => !t.isActive);
    notifyListeners();
  }

  /// 在系统文件管理器中打开任务所在目录（仅桌面端）。
  Future<void> revealInFolder(DownloadTask task) async {
    final target = task.outputFile;
    try {
      if (Platform.isWindows) {
        if (target != null && File(target).existsSync()) {
          await Process.run('explorer', ['/select,', target]);
        } else {
          await Process.run('explorer', [task.outputDir]);
        }
      } else if (Platform.isMacOS) {
        await Process.run('open', [target ?? task.outputDir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [task.outputDir]);
      }
    } catch (_) {}
  }
}
