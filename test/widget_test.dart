import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vdownload/models/download_task.dart';
import 'package:vdownload/models/video_info.dart';
import 'package:vdownload/services/bilibili_live_service.dart';
import 'package:vdownload/services/download_manager.dart';
import 'package:vdownload/services/engine/video_engine.dart';
import 'package:vdownload/services/settings_service.dart';
import 'package:vdownload/utils/format_utils.dart';

class _FakeEngine extends VideoEngine {
  EngineOutputCallback? lastCallback;
  Completer<void>? activeCompleter;
  bool stopCalled = false;

  @override
  bool get isBundled => false;

  @override
  Future<void> cancel(String taskId) async {
    activeCompleter?.complete();
  }

  @override
  Future<void> download(DownloadSpec spec, EngineOutputCallback onOutput) async {
    lastCallback = onOutput;
    activeCompleter = Completer<void>();
    await activeCompleter!.future;
  }

  @override
  Future<String?> splitCheckpoint(String taskId) async {
    const segPath = '/tmp/live_part1.mp4';
    lastCallback?.call(null, null, '[live-segment] $segPath');
    return segPath;
  }

  @override
  Future<void> stopAndSave(String taskId) async {
    stopCalled = true;
    lastCallback?.call(null, null, '[live-finalizing]');
    lastCallback?.call(null, null, '[live-saved] /tmp/live_part2.mp4');
    activeCompleter?.complete();
  }

  @override
  Future<Map<String, dynamic>> fetchInfoJson(String url) async => {};

  @override
  Future<String> version() async => 'test';
}

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
    expect(info.hasSeparateAudioFormats, isTrue);
    expect(info.isLive, isFalse);
  });

  test('Bilibili 直播无 height 时也能归并画质档位并识别为直播', () {
    final info = VideoInfo.fromJson({
      'id': '196',
      'title': 'B站直播测试',
      'webpage_url': 'https://live.bilibili.com/196',
      'extractor_key': 'BiliLive',
      'is_live': true,
      'formats': [
        {
          'format_id': 'high_res',
          'format_note': '高清',
          'ext': 'flv',
          'vcodec': 'avc',
          'quality': 1,
        },
        {
          'format_id': 'source',
          'format_note': '原画',
          'ext': 'flv',
          'vcodec': 'hevc',
          'quality': 4,
        },
        {
          'format_id': 'source',
          'format_note': '原画',
          'ext': 'fmp4',
          'vcodec': 'avc',
          'quality': 4,
        },
      ],
    });
    expect(info.isLive, isTrue);
    expect(info.hasSeparateAudioFormats, isFalse);
    final q = info.videoQualities;
    expect(q.length, 2);
    expect(q.first.displayLabel, '原画');
    expect(q.first.ext, 'fmp4');
    expect(q.last.displayLabel, '高清');
  });

  test('YouTube 直播通过 live_status=is_live 识别', () {
    final info = VideoInfo.fromJson({
      'id': 'ytlive',
      'title': 'YouTube Live Stream',
      'webpage_url': 'https://www.youtube.com/watch?v=ytlive',
      'extractor_key': 'Youtube',
      'live_status': 'is_live',
      'formats': [
        {'format_id': '95', 'ext': 'mp4', 'height': 720, 'fps': 60, 'vcodec': 'avc1', 'acodec': 'mp4a', 'tbr': 3500},
        {'format_id': '96', 'ext': 'mp4', 'height': 1080, 'fps': 60, 'vcodec': 'avc1', 'acodec': 'mp4a', 'tbr': 6000},
      ],
    });
    expect(info.isLive, isTrue);
    expect(info.isYouTube, isTrue);
    expect(info.videoQualities.first.displayLabel, '1080P 60fps');
  });

  test('DownloadManager 解析直播实时状态与断点片段事件', () async {
    final fakeEngine = _FakeEngine();
    final manager = DownloadManager(SettingsService(), fakeEngine);
    final tmpDir = Directory.systemTemp.createTempSync('vdown_test_');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final task = DownloadTask(
      id: 't1',
      url: 'https://live.bilibili.com/196',
      title: '直播测试',
      qualityLabel: '直播 原画 · MP4',
      formatSelector: 'source/best',
      outputDir: tmpDir.path,
      isLive: true,
    );

    manager.enqueue(task);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(task.status, TaskStatus.recording);
    expect(task.isActive, isTrue);

    fakeEngine.lastCallback?.call(
      null,
      null,
      '[live-progress] time=00:01:23|size=18.5 MB|bitrate=3200kbits/s|speed=1.0x|seg=2',
    );
    expect(task.recordedDuration, '00:01:23');
    expect(task.recordedSize, '18.5 MB');
    expect(task.bitrate, '3200kbits/s');
    expect(task.segmentIndex, 2);

    final seg = await manager.splitCheckpoint(task);
    expect(seg, '/tmp/live_part1.mp4');
    expect(task.savedFiles, ['/tmp/live_part1.mp4']);
    expect(task.outputFile, '/tmp/live_part1.mp4');

    await manager.stopAndSave(task);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(fakeEngine.stopCalled, isTrue);
    expect(task.status, TaskStatus.done);
    expect(task.progress, 1.0);
    expect(task.savedFiles, ['/tmp/live_part1.mp4', '/tmp/live_part2.mp4']);
    expect(task.outputFile, '/tmp/live_part2.mp4');
  });

  test('BilibiliLiveService 识别直播间与 Cookie 规范化及 authLimited 标记', () {
    expect(BilibiliLiveService.isBilibiliLiveUrl('https://live.bilibili.com/6'), isTrue);
    expect(BilibiliLiveService.extractRoomId('https://live.bilibili.com/blanc/196?foo=1'), '196');
    expect(BilibiliLiveService.normalizeCookieHeader('abc123'), 'SESSDATA=abc123');
    expect(
      BilibiliLiveService.normalizeCookieHeader('SESSDATA=abc; DedeUserID=1'),
      'SESSDATA=abc; DedeUserID=1',
    );

    final info = VideoInfo.fromJson({
      'id': '7734200',
      'title': '1080P受限测试',
      'webpage_url': 'https://live.bilibili.com/6',
      'is_live': true,
      'bili_auth_limited': true,
      'formats': [
        {
          'format_id': '10000_fmp4_avc',
          'format_note': '1080P 原画',
          'ext': 'fmp4',
          'vcodec': 'avc',
          'quality': 10000,
        },
        {
          'format_id': '400_fmp4_avc',
          'format_note': '1080P 蓝光',
          'ext': 'fmp4',
          'vcodec': 'avc',
          'quality': 400,
        },
        {
          'format_id': '250_fmp4_hevc',
          'format_note': '720P 超清',
          'ext': 'fmp4',
          'vcodec': 'hevc',
          'quality': 250,
        },
      ],
    });
    expect(info.biliAuthLimited, isTrue);
    final q = info.videoQualities;
    expect(q.map((e) => e.displayLabel).toList(), ['1080P 原画', '1080P 蓝光', '720P 超清']);
  });
}
