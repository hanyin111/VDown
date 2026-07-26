enum TaskStatus { queued, running, merging, done, error, canceled }

/// 一条下载任务。进度字段由 DownloadManager 在解析 yt-dlp 输出时更新。
class DownloadTask {
  final String id;
  final String url;
  final String title;
  final String? thumbnail;

  /// 展示给用户的清晰度标签，如 "1080P · mp4" 或 "音频 MP3"。
  final String qualityLabel;

  /// 传给 yt-dlp -f 的格式选择器。
  final String formatSelector;
  final bool audioOnly;

  /// 是否同时下载 CC 字幕（转为 SRT）。
  final bool withSubtitles;
  final String outputDir;

  TaskStatus status;
  double progress; // 0.0 - 1.0
  String? totalSize;
  String? speed;
  String? eta;
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
    this.status = TaskStatus.queued,
    this.progress = 0,
  });

  bool get isActive =>
      status == TaskStatus.queued ||
      status == TaskStatus.running ||
      status == TaskStatus.merging;
}
