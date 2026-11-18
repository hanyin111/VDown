import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/download_task.dart';
import '../../models/video_info.dart';
import '../../services/download_manager.dart';
import '../../services/engine/video_engine.dart';
import '../../services/settings_service.dart';
import '../../services/ytdlp_service.dart';
import '../../utils/format_utils.dart';
import '../widgets/bili_login_dialog.dart';

class DownloadPage extends StatefulWidget {
  final VoidCallback onGoToTasks;

  const DownloadPage({super.key, required this.onGoToTasks});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _urlController = TextEditingController();
  bool _loading = false;
  String? _error;
  VideoInfo? _info;

  /// 选中的清晰度；null 表示"音频 MP3"。
  VideoFormat? _selected;
  bool _audioSelected = false;
  bool _withSubs = false;
  bool _liveFromStart = false;

  /// null 表示手动停止（支持任意时间戳断点保存）；正整数表示定时上限（秒）。
  int? _liveDurationLimitSec;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      // 分享文案自动提取其中的链接
      _urlController.text = extractUrl(text) ?? text;
    }
  }

  Future<void> _parse() async {
    final raw = _urlController.text.trim();
    if (raw.isEmpty) return;
    final url = extractUrl(raw) ?? raw;
    if (url != raw) _urlController.text = url;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _selected = null;
      _audioSelected = false;
      _withSubs = false;
      _liveFromStart = false;
      _liveDurationLimitSec = null;
    });
    try {
      final service = YtdlpService(context.read<VideoEngine>());
      final info = await service.fetchInfo(url);
      if (!mounted) return;
      final qualities = info.videoQualities;
      setState(() {
        _info = info;
        _selected = qualities.isNotEmpty ? qualities.first : null;
        _audioSelected = qualities.isEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static String? _biliLiveYtdlpAlias(String formatId) {
    if (formatId.startsWith('30000_')) return 'dolby';
    if (formatId.startsWith('20000_')) return '4K';
    if (formatId.startsWith('10000_')) return 'source';
    if (formatId.startsWith('400_')) return 'blue_ray';
    if (formatId.startsWith('250_')) return 'ultra_high_res';
    if (formatId.startsWith('150_')) return 'high_res';
    if (formatId.startsWith('80_')) return 'low';
    return null;
  }

  Future<void> _promptBiliLoginAndReparse() async {
    final ok = await BiliLoginDialog.show(context);
    if (ok && mounted) {
      await _parse();
    }
  }

  void _startDownload() {
    final info = _info;
    if (info == null) return;
    final settings = context.read<SettingsService>();
    final manager = context.read<DownloadManager>();

    final String selector;
    final String label;
    if (_audioSelected || _selected == null) {
      selector = 'bestaudio/best';
      label = info.isLive ? '直播音频 · MP3' : '音频 · MP3';
    } else {
      final f = _selected!;
      // 若平台存在独立音轨（如 YouTube / B站点播），无内嵌音频的流需合并 bestaudio；
      // B 站直播等合流（无独立 audio-only 格式）直接取该格式即可，避免多余回退。
      final needsBestAudio = !f.hasAudio && info.hasSeparateAudioFormats;
      final biliAlias = _biliLiveYtdlpAlias(f.formatId);
      selector = needsBestAudio
          ? '${f.formatId}+bestaudio/${f.formatId}/best'
          : (biliAlias != null
              ? '${f.formatId}/$biliAlias/best'
              : '${f.formatId}/best');
      label = info.isLive
          ? '直播 ${f.displayLabel} · MP4'
          : '${f.displayLabel} · MP4';
    }

    manager.enqueue(DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: info.webpageUrl.isNotEmpty
          ? info.webpageUrl
          : _urlController.text.trim(),
      title: info.title,
      thumbnail: info.thumbnail,
      qualityLabel: label,
      formatSelector: selector,
      outputDir: settings.downloadDir,
      audioOnly: _audioSelected,
      withSubtitles: !info.isLive && _withSubs,
      isLive: info.isLive,
      liveFromStart: info.isLive && info.isYouTube && _liveFromStart,
      maxDurationSeconds: info.isLive ? _liveDurationLimitSec : null,
    ));

    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    final ctrl = messenger.showSnackBar(SnackBar(
      content: Text(
        info.isLive
            ? '已开始实时录制直播：${info.title}'
            : '已加入下载队列：${info.title}',
      ),
      duration: const Duration(seconds: 3),
      action: SnackBarAction(label: '查看任务', onPressed: widget.onGoToTasks),
    ));
    // 无障碍导航开启时，带 action 的 SnackBar 不会自动超时，手动定时关闭。
    Timer(const Duration(milliseconds: 3200), () {
      try {
        ctrl.close();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth > 720;
      return SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: wide ? (constraints.maxWidth - 680) / 2 : 20,
          vertical: 32,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            Icon(Icons.download_rounded, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              '粘贴链接，开始下载',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '支持 YouTube · Bilibili（含直播实时录制与任意时间戳断点保存）等 1800+ 网站',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      hintText: 'https://…',
                      prefixIcon: const Icon(Icons.link_rounded),
                      suffixIcon: IconButton(
                        tooltip: '粘贴',
                        icon: const Icon(Icons.content_paste_rounded),
                        onPressed: _pasteFromClipboard,
                      ),
                    ),
                    onSubmitted: (_) => _parse(),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 58,
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _parse,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search_rounded),
                    label: Text(_loading ? '解析中' : '解析'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_error != null) _ErrorCard(message: _error!),
            if (_info != null) ...[
              _VideoInfoCard(info: _info!),
              if (_info!.biliAuthLimited) ...[
                const SizedBox(height: 16),
                Card(
                  color: scheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.hd_rounded,
                            color: scheme.onSecondaryContainer),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '当前未登录 B 站账号，服务端限制最高返回 720P；扫码登录后可解锁 1080P 原画 / 蓝光 / 2K。',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSecondaryContainer),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: _promptBiliLoginAndReparse,
                          child: const Text('扫码登录'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _buildQualitySelector(),
              if (_info!.isLive) ...[
                const SizedBox(height: 20),
                _buildLiveOptions(),
              ],
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: _startDownload,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                icon: Icon(_info!.isLive
                    ? Icons.fiber_manual_record_rounded
                    : Icons.download_rounded),
                label: Text(_info!.isLive ? '开始实时录制（支持任意时刻断点保存）' : '开始下载'),
              ),
            ],
          ],
        ),
      );
    });
  }

  Widget _buildQualitySelector() {
    final info = _info!;
    final qualities = info.videoQualities;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(info.isLive ? '选择直播画质' : '选择清晰度',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in qualities)
              ChoiceChip(
                label: Text(f.displayLabel),
                selected: !_audioSelected && _selected?.formatId == f.formatId,
                onSelected: (_) => setState(() {
                  _selected = f;
                  _audioSelected = false;
                }),
              ),
            ChoiceChip(
              avatar: _audioSelected
                  ? null
                  : Icon(Icons.music_note_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
              label: const Text('仅音频 MP3'),
              selected: _audioSelected,
              onSelected: (_) => setState(() => _audioSelected = true),
            ),
          ],
        ),
        if (!info.isLive && info.subtitleLangs.isNotEmpty) ...[
          const SizedBox(height: 12),
          FilterChip(
            avatar: _withSubs
                ? null
                : Icon(Icons.subtitles_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
            label: Text('同时下载 CC 字幕（${info.subtitleLangs.length} 种语言，SRT）'),
            selected: _withSubs,
            onSelected: (v) => setState(() => _withSubs = v),
          ),
        ],
        if (!_audioSelected && _selected != null) ...[
          const SizedBox(height: 12),
          Text(
            info.isLive
                ? '格式 ${_selected!.ext.toUpperCase()} · 编码 ${_selected!.vcodec ?? '未知'} · 实时封装为可播放 MP4'
                : '格式 ${_selected!.ext.toUpperCase()} · 编码 ${_selected!.vcodec ?? '未知'} · ${formatBytes(_selected!.filesize)}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _buildLiveOptions() {
    final info = _info!;
    final scheme = Theme.of(context).colorScheme;
    const durationOptions = <(int?, String)>[
      (null, '手动停止（任意时刻断点保存）'),
      (1800, '30 分钟'),
      (3600, '1 小时'),
      (7200, '2 小时'),
    ];

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sensors_rounded, size: 20, color: scheme.error),
                const SizedBox(width: 8),
                Text(
                  '直播实时录制设置',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '录制过程采用碎片化实时写入，在任务页可随时点击「断点保存」切分片段，或「停止并保存」生成标准可播放 MP4。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Text(
              '录制时长上限',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final opt in durationOptions)
                  ChoiceChip(
                    label: Text(opt.$2),
                    selected: _liveDurationLimitSec == opt.$1,
                    onSelected: (_) =>
                        setState(() => _liveDurationLimitSec = opt.$1),
                  ),
              ],
            ),
            if (info.isYouTube) ...[
              const SizedBox(height: 10),
              FilterChip(
                avatar: _liveFromStart
                    ? null
                    : Icon(Icons.history_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                label: const Text('尝试从直播开头回溯录制（YouTube DVR）'),
                selected: _liveFromStart,
                onSelected: (v) => setState(() => _liveFromStart = v),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VideoInfoCard extends StatelessWidget {
  final VideoInfo info;

  const _VideoInfoCard({required this.info});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 160,
                height: 90,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    info.thumbnail != null
                        ? Image.network(
                            info.thumbnail!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _placeholder(scheme),
                          )
                        : _placeholder(scheme),
                    if (info.isLive)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: scheme.error,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'LIVE 直播中',
                            style: TextStyle(
                              color: scheme.onError,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (info.uploader != null) info.uploader!,
                      info.isLive ? '实时直播' : formatDuration(info.durationSeconds),
                      if (info.extractor != null) info.extractor!,
                    ].join(' · '),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.movie_rounded, color: scheme.onSurfaceVariant),
      );
}

class _ErrorCard extends StatelessWidget {
  final String message;

  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
