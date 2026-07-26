import 'package:flutter_test/flutter_test.dart';

import 'package:vdownload/models/video_info.dart';

void main() {
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
