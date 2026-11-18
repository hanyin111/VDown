import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/download_task.dart';
import '../../services/download_manager.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final tasks = manager.tasks;
    final scheme = Theme.of(context).colorScheme;

    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_rounded,
                size: 64, color: scheme.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text('暂无下载任务',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    final hasFinished = tasks.any((t) => !t.isActive);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Row(
            children: [
              Text('下载任务',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (hasFinished)
                TextButton.icon(
                  onPressed: manager.clearFinished,
                  icon: const Icon(Icons.clear_all_rounded),
                  label: const Text('清除已完成'),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            itemCount: tasks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) => _TaskCard(task: tasks[index]),
          ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  final DownloadTask task;

  const _TaskCard({required this.task});

  @override
  Widget build(BuildContext context) {
    final manager = context.read<DownloadManager>();
    final scheme = Theme.of(context).colorScheme;

    return Card.outlined(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 112,
                height: 63,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    task.thumbnail != null
                        ? Image.network(
                            task.thumbnail!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _placeholder(scheme),
                          )
                        : _placeholder(scheme),
                    if (task.isLive)
                      Positioned(
                        left: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: task.status == TaskStatus.recording
                                ? scheme.error
                                : scheme.secondary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'LIVE',
                            style: TextStyle(
                              color: task.status == TaskStatus.recording
                                  ? scheme.onError
                                  : scheme.onSecondary,
                              fontSize: 9,
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
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  _buildStatusLine(context),
                  if (task.savedFiles.isNotEmpty &&
                      task.status == TaskStatus.recording) ...[
                    const SizedBox(height: 4),
                    Text(
                      '已断点保存 ${task.savedFiles.length} 个可播放片段',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: scheme.primary),
                    ),
                  ],
                  if (task.status == TaskStatus.running ||
                      task.status == TaskStatus.recording ||
                      task.status == TaskStatus.merging ||
                      task.status == TaskStatus.finalizing) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (task.status == TaskStatus.merging ||
                                task.status == TaskStatus.recording ||
                                task.status == TaskStatus.finalizing)
                            ? null
                            : task.progress,
                        minHeight: 6,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            ..._buildActions(context, manager),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.movie_rounded,
            size: 20, color: scheme.onSurfaceVariant),
      );

  Widget _buildStatusLine(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);

    switch (task.status) {
      case TaskStatus.queued:
        return Text('${task.qualityLabel} · 排队中…', style: style);
      case TaskStatus.running:
        final parts = [
          task.qualityLabel,
          '${(task.progress * 100).toStringAsFixed(1)}%',
          if (task.totalSize != null) task.totalSize!,
          if (task.speed != null) task.speed!,
          if (task.eta != null) '剩余 ${task.eta}',
        ];
        return Text(parts.join(' · '), style: style);
      case TaskStatus.recording:
        final parts = [
          task.qualityLabel,
          if (task.segmentIndex > 1) '第 ${task.segmentIndex} 段',
          '已录 ${task.recordedDuration ?? '00:00:00'}',
          if (task.recordedSize != null) task.recordedSize!,
          if (task.bitrate != null) task.bitrate!,
          if (task.speed != null) task.speed!,
        ];
        return Text(parts.join(' · '), style: style);
      case TaskStatus.merging:
        return Text('${task.qualityLabel} · 正在合并音视频…', style: style);
      case TaskStatus.finalizing:
        return Text('${task.qualityLabel} · 正在封装为可播放视频…', style: style);
      case TaskStatus.done:
        return Row(children: [
          Icon(Icons.check_circle_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              task.savedFiles.length > 1
                  ? '${task.qualityLabel} · 已保存 ${task.savedFiles.length} 个视频'
                  : '${task.qualityLabel} · 已完成',
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ]);
      case TaskStatus.error:
        return Text(
          task.errorMessage ?? '下载失败',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style?.copyWith(color: scheme.error),
        );
      case TaskStatus.canceled:
        return Text('${task.qualityLabel} · 已取消', style: style);
    }
  }

  List<Widget> _buildActions(BuildContext context, DownloadManager manager) {
    switch (task.status) {
      case TaskStatus.recording:
        return [
          IconButton(
            tooltip: '断点保存片段（继续录制）',
            icon: const Icon(Icons.bookmark_add_rounded),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final saved = await manager.splitCheckpoint(task);
              if (saved != null && context.mounted) {
                messenger.showSnackBar(SnackBar(
                  content: Text('已断点保存可播放片段：$saved'),
                  duration: const Duration(seconds: 3),
                ));
              }
            },
          ),
          FilledButton.tonalIcon(
            onPressed: () => manager.stopAndSave(task),
            icon: const Icon(Icons.stop_circle_rounded, size: 18),
            label: const Text('停止并保存'),
          ),
        ];
      case TaskStatus.finalizing:
        return [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ];
      case TaskStatus.queued:
      case TaskStatus.running:
      case TaskStatus.merging:
        return [
          IconButton(
            tooltip: '取消',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => manager.cancel(task),
          ),
        ];
      case TaskStatus.done:
        return [
          IconButton(
            tooltip: '打开所在文件夹',
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: () => manager.revealInFolder(task),
          ),
          IconButton(
            tooltip: '移除记录',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => manager.remove(task),
          ),
        ];
      case TaskStatus.error:
      case TaskStatus.canceled:
        return [
          IconButton(
            tooltip: '重试',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => manager.retry(task),
          ),
          IconButton(
            tooltip: '移除记录',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => manager.remove(task),
          ),
        ];
    }
  }
}
