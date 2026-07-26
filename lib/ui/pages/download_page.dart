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

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _urlController.text = text;
    }
  }

  Future<void> _parse() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _selected = null;
      _audioSelected = false;
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

  void _startDownload() {
    final info = _info;
    if (info == null) return;
    final settings = context.read<SettingsService>();
    final manager = context.read<DownloadManager>();

    final String selector;
    final String label;
    if (_audioSelected || _selected == null) {
      selector = 'bestaudio/best';
      label = '音频 · MP3';
    } else {
      final f = _selected!;
      // 无内置音轨时与最佳音轨合并（B 站 / YouTube 高清流均为分离音视频）。
      selector = f.hasAudio
          ? '${f.formatId}/best'
          : '${f.formatId}+bestaudio/${f.formatId}/best';
      label = '${f.height}P${(f.fps ?? 0) > 40 ? '${f.fps!.round()}' : ''} · MP4';
    }

    manager.enqueue(DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: info.webpageUrl.isNotEmpty ? info.webpageUrl : _urlController.text.trim(),
      title: info.title,
      thumbnail: info.thumbnail,
      qualityLabel: label,
      formatSelector: selector,
      outputDir: settings.downloadDir,
      audioOnly: _audioSelected,
    ));

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已加入下载队列：${info.title}'),
      action: SnackBarAction(label: '查看任务', onPressed: widget.onGoToTasks),
    ));
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
              '支持 YouTube · Bilibili · X（Twitter）等 1800+ 网站',
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
              const SizedBox(height: 20),
              _buildQualitySelector(),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: _startDownload,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                icon: const Icon(Icons.download_rounded),
                label: const Text('开始下载'),
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
        Text('选择清晰度',
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
                label: Text(
                  '${f.height}P${(f.fps ?? 0) > 40 ? ' ${f.fps!.round()}fps' : ''}',
                ),
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
        if (!_audioSelected && _selected != null) ...[
          const SizedBox(height: 12),
          Text(
            '格式 ${_selected!.ext.toUpperCase()} · 编码 ${_selected!.vcodec ?? '未知'} · ${formatBytes(_selected!.filesize)}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
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
                child: info.thumbnail != null
                    ? Image.network(
                        info.thumbnail!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(scheme),
                      )
                    : _placeholder(scheme),
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
                      formatDuration(info.durationSeconds),
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
