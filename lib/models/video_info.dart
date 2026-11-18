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
  final String? formatNote;
  final double? quality;
  final String? protocol;
  final String? url;
  final Map<String, String> httpHeaders;

  const VideoFormat({
    required this.formatId,
    required this.ext,
    this.height,
    this.fps,
    this.vcodec,
    this.acodec,
    this.filesize,
    this.tbr,
    this.formatNote,
    this.quality,
    this.protocol,
    this.url,
    this.httpHeaders = const {},
  });

  bool get hasVideo => vcodec != null && vcodec != 'none';
  bool get hasAudio => acodec != null && acodec != 'none';
  bool get isAudioOnly => hasAudio && !hasVideo;

  String get displayLabel {
    if (height != null && height! > 0) {
      return '${height}P${(fps ?? 0) > 40 ? ' ${fps!.round()}fps' : ''}';
    }
    if (formatNote != null && formatNote!.isNotEmpty) {
      return formatNote!;
    }
    return formatId;
  }

  factory VideoFormat.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['http_headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        if (entry.key != null && entry.value != null) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      }
    }
    return VideoFormat(
      formatId: json['format_id']?.toString() ?? '',
      ext: json['ext']?.toString() ?? '',
      height: (json['height'] as num?)?.toInt(),
      fps: (json['fps'] as num?)?.toDouble(),
      vcodec: json['vcodec']?.toString(),
      acodec: json['acodec']?.toString(),
      filesize: ((json['filesize'] ?? json['filesize_approx']) as num?)?.toInt(),
      tbr: (json['tbr'] as num?)?.toDouble(),
      formatNote: json['format_note']?.toString(),
      quality: (json['quality'] as num?)?.toDouble(),
      protocol: json['protocol']?.toString(),
      url: json['url']?.toString(),
      httpHeaders: headers,
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
  final bool isLive;
  final String? liveStatus;
  final bool biliAuthLimited;
  final Map<String, String> httpHeaders;
  final List<VideoFormat> formats;

  /// 可用的 CC 字幕语言（不含 B 站弹幕轨）。
  final List<String> subtitleLangs;

  const VideoInfo({
    required this.id,
    required this.title,
    required this.webpageUrl,
    this.uploader,
    this.thumbnail,
    this.durationSeconds,
    this.extractor,
    this.isLive = false,
    this.liveStatus,
    this.biliAuthLimited = false,
    this.httpHeaders = const {},
    this.formats = const [],
    this.subtitleLangs = const [],
  });

  bool get hasSeparateAudioFormats => formats.any((f) => f.isAudioOnly);

  bool get isYouTube =>
      (extractor ?? '').toLowerCase().contains('youtube') ||
      webpageUrl.contains('youtube.com') ||
      webpageUrl.contains('youtu.be');

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    final rawFormats = (json['formats'] as List?) ?? const [];
    final subs = (json['subtitles'] as Map?)
            ?.keys
            .map((k) => k.toString())
            .where((k) => k != 'danmaku') // B 站弹幕不算字幕
            .toList() ??
        const <String>[];
    final liveStatus = json['live_status']?.toString();
    final isLive = json['is_live'] == true || liveStatus == 'is_live';
    final rawHeaders = json['http_headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        if (entry.key != null && entry.value != null) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      }
    }
    return VideoInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名视频',
      uploader: (json['uploader'] ?? json['channel'])?.toString(),
      thumbnail: json['thumbnail']?.toString(),
      durationSeconds: (json['duration'] as num?)?.toInt(),
      webpageUrl: json['webpage_url']?.toString() ?? '',
      extractor: json['extractor_key']?.toString(),
      isLive: isLive,
      liveStatus: liveStatus,
      biliAuthLimited: json['bili_auth_limited'] == true,
      httpHeaders: headers,
      formats: rawFormats
          .whereType<Map<String, dynamic>>()
          .map(VideoFormat.fromJson)
          .where((f) => f.formatId.isNotEmpty)
          .toList(),
      subtitleLangs: subs,
    );
  }

  /// 按分辨率（或直播画质档位）归并出的可选清晰度列表，降序排列。
  /// 兼容有明确 height 的格式（YouTube / B站点播）以及无 height 的直播流（B站直播仅返回 format_note / quality）。
  List<VideoFormat> get videoQualities {
    final byHeight = <int, VideoFormat>{};
    final byNote = <String, VideoFormat>{};

    for (final f in formats) {
      if (!f.hasVideo) continue;
      if (f.height != null && f.height! > 0) {
        final existing = byHeight[f.height!];
        if (existing == null || _preferFormat(f, existing)) {
          byHeight[f.height!] = f;
        }
      } else {
        final key = (f.formatNote != null && f.formatNote!.isNotEmpty)
            ? f.formatNote!
            : f.formatId;
        final existing = byNote[key];
        if (existing == null || _preferFormat(f, existing)) {
          byNote[key] = f;
        }
      }
    }

    if (byHeight.isNotEmpty) {
      final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
      return [for (final h in heights) byHeight[h]!];
    }

    final noHeight = byNote.values.toList()
      ..sort((a, b) {
        final qCmp = (b.quality ?? -1).compareTo(a.quality ?? -1);
        if (qCmp != 0) return qCmp;
        return (b.tbr ?? 0).compareTo(a.tbr ?? 0);
      });
    return noHeight;
  }

  static bool _preferFormat(VideoFormat candidate, VideoFormat current) {
    final cTbr = candidate.tbr ?? 0;
    final curTbr = current.tbr ?? 0;
    if (cTbr != curTbr) return cTbr > curTbr;
    // 码率未知或相同时（如 B 站直播多路流），优先 H.264 / fmp4 / ts / flv / mp4
    int score(VideoFormat f) {
      var s = 0;
      final vc = (f.vcodec ?? '').toLowerCase();
      if (vc.contains('avc') || vc.contains('h264')) s += 4;
      final ext = f.ext.toLowerCase();
      if (ext == 'mp4' || ext == 'fmp4') {
        s += 3;
      } else if (ext == 'ts' || ext == 'm3u8') {
        s += 2;
      } else if (ext == 'flv') {
        s += 1;
      }
      if (f.hasAudio) s += 2;
      return s;
    }

    return score(candidate) > score(current);
  }
}
