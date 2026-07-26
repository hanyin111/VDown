/// yt-dlp `-J` 输出中单个可下载格式的精简模型。
class VideoFormat {
  final String formatId;
  final String ext;
  final int? height;
  final double? fps;
  final String? vcodec;
  final String? acodec;
  final int? filesize;
  final double? tbr;

  const VideoFormat({
    required this.formatId,
    required this.ext,
    this.height,
    this.fps,
    this.vcodec,
    this.acodec,
    this.filesize,
    this.tbr,
  });

  bool get hasVideo => vcodec != null && vcodec != 'none';
  bool get hasAudio => acodec != null && acodec != 'none';

  factory VideoFormat.fromJson(Map<String, dynamic> json) {
    return VideoFormat(
      formatId: json['format_id']?.toString() ?? '',
      ext: json['ext']?.toString() ?? '',
      height: (json['height'] as num?)?.toInt(),
      fps: (json['fps'] as num?)?.toDouble(),
      vcodec: json['vcodec']?.toString(),
      acodec: json['acodec']?.toString(),
      filesize: ((json['filesize'] ?? json['filesize_approx']) as num?)?.toInt(),
      tbr: (json['tbr'] as num?)?.toDouble(),
    );
  }
}

/// 解析后的视频信息。
class VideoInfo {
  final String id;
  final String title;
  final String? uploader;
  final String? thumbnail;
  final int? durationSeconds;
  final String webpageUrl;
  final String? extractor;
  final List<VideoFormat> formats;

  const VideoInfo({
    required this.id,
    required this.title,
    required this.webpageUrl,
    this.uploader,
    this.thumbnail,
    this.durationSeconds,
    this.extractor,
    this.formats = const [],
  });

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    final rawFormats = (json['formats'] as List?) ?? const [];
    return VideoInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名视频',
      uploader: (json['uploader'] ?? json['channel'])?.toString(),
      thumbnail: json['thumbnail']?.toString(),
      durationSeconds: (json['duration'] as num?)?.toInt(),
      webpageUrl: json['webpage_url']?.toString() ?? '',
      extractor: json['extractor_key']?.toString(),
      formats: rawFormats
          .whereType<Map<String, dynamic>>()
          .map(VideoFormat.fromJson)
          .where((f) => f.formatId.isNotEmpty)
          .toList(),
    );
  }

  /// 按分辨率归并出的可选清晰度列表（每档取码率最高的一条），降序排列。
  List<VideoFormat> get videoQualities {
    final byHeight = <int, VideoFormat>{};
    for (final f in formats) {
      if (!f.hasVideo || f.height == null || f.height! <= 0) continue;
      final existing = byHeight[f.height!];
      if (existing == null || (f.tbr ?? 0) > (existing.tbr ?? 0)) {
        byHeight[f.height!] = f;
      }
    }
    final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final h in heights) byHeight[h]!];
  }
}
