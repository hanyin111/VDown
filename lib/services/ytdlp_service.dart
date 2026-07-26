import '../models/video_info.dart';
import 'engine/video_engine.dart';

/// 面向 UI 的解析门面：调用底层引擎并转换为 [VideoInfo]。
class YtdlpService {
  final VideoEngine engine;

  YtdlpService(this.engine);

  Future<VideoInfo> fetchInfo(String url) async {
    final json = await engine.fetchInfoJson(url);
    // 播放列表页取第一个条目。
    if (json['_type'] == 'playlist') {
      final entries = json['entries'] as List?;
      if (entries != null && entries.isNotEmpty) {
        return VideoInfo.fromJson(entries.first as Map<String, dynamic>);
      }
    }
    return VideoInfo.fromJson(json);
  }

  Future<String> version() => engine.version();
}
