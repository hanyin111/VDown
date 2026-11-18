enum TaskStatus {
  queued,
  running,
  recording,
  merging,
  finalizing,
  done,
  error,
  canceled,
}

/// 一条下载或直播录制任务。进度字段由 DownloadManager 在解析引擎输出时更新。
class DownloadTask {
  final String id;
  final String url;
  final String title;
  final String? thumbnail;

  /// 展示给用户的清晰度标签，如 "1080P · MP4" 或 "音频 · MP3"。
  final String qualityLabel;

  /// 传给 yt-dlp -f 的格式选择器。
  final String formatSelector;
  final bool audioOnly;

  /// 是否同时下载 CC 字幕（转为 SRT）。
  final bool withSubtitles;
  final String outputDir;

  /// 直播录制相关配置与实时状态。
  final bool isLive;
  final bool liveFromStart;
  final int? maxDurationSeconds;

  TaskStatus status;
  double progress; // 0.0 - 1.0
  String? totalSize;
  String? speed;
  String? eta;
  String? recordedDuration;
  String? recordedSize;
  String? bitrate;
  int segmentIndex;
  final List<String> savedFiles;
  String? errorMessage;
  String? outputFile;

  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    required this.qualityLabel,
    required this.formatSelector,
    required this.outputDir,
    this.thumbnail,
    this.audioOnly = false,
    this.withSubtitles = false,
    this.isLive = false,
    this.liveFromStart = false,
    this.maxDurationSeconds,
    this.status = TaskStatus.queued,
    this.progress = 0,
    this.segmentIndex = 1,
    List<String>? savedFiles,
  }) : savedFiles = savedFiles ?? [];

  bool get isActive =>
      status == TaskStatus.queued ||
      status == TaskStatus.running ||
      status == TaskStatus.recording ||
      status == TaskStatus.merging ||
      status == TaskStatus.finalizing;
}
