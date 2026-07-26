/// 展示用的格式化工具。
String formatDuration(int? seconds) {
  if (seconds == null || seconds <= 0) return '--:--';
  final d = Duration(seconds: seconds);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 从任意文本中提取第一个 http(s) 链接。
/// B 站等平台的分享文案通常是「【标题】 https://b23.tv/xxx 复制这段内容…」，
/// 链接到空白或中文字符（含全角标点）为止。
String? extractUrl(String text) {
  return RegExp(r'https?://[^\s　-￿]+').firstMatch(text)?.group(0);
}

String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '未知大小';
  const units = ['B', 'KB', 'MB', 'GB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}
