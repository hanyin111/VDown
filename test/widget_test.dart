import 'package:flutter_test/flutter_test.dart';

import 'package:vdownload/models/video_info.dart';
import 'package:vdownload/utils/format_utils.dart';

void main() {
  test('extractUrl 从分享文案中提取链接', () {
    expect(
      extractUrl('【4K修复】星际穿越 https://b23.tv/AbCd123 复制这段内容打开哔哩哔哩'),
      'https://b23.tv/AbCd123',
    );
    expect(
      extractUrl('看看这个 https://www.bilibili.com/video/BV1xx411c7mD/?share_source=copy_web，很不错'),
      'https://www.bilibili.com/video/BV1xx411c7mD/?share_source=copy_web',
    );
    expect(
      extractUrl('https://youtu.be/dQw4w9WgXcQ'),
      'https://youtu.be/dQw4w9WgXcQ',
    );
    expect(extractUrl('没有链接的文字'), isNull);
  });

  test('videoQualities 按分辨率归并并降序排列', () {
    final info = VideoInfo.fromJson({
      'id': 'x',
      'title': 't',
      'webpage_url': 'https://example.com',
      'formats': [
        {'format_id': '1', 'ext': 'mp4', 'height': 720, 'vcodec': 'avc1', 'tbr': 1000},
        {'format_id': '2', 'ext': 'mp4', 'height': 1080, 'vcodec': 'avc1', 'tbr': 2000},
        {'format_id': '3', 'ext': 'mp4', 'height': 1080, 'vcodec': 'avc1', 'tbr': 2500},
        {'format_id': '4', 'ext': 'm4a', 'vcodec': 'none', 'acodec': 'mp4a', 'tbr': 128},
      ],
    });
    final q = info.videoQualities;
    expect(q.length, 2);
    expect(q.first.height, 1080);
    expect(q.first.formatId, '3');
    expect(q.last.height, 720);
  });
}
