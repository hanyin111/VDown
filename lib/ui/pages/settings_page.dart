import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/engine/video_engine.dart';
import '../../services/settings_service.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final scheme = Theme.of(context).colorScheme;

    Widget sectionHeader(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
        );

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth > 720;
      return ListView(
        padding: EdgeInsets.symmetric(
          horizontal: wide ? (constraints.maxWidth - 680) / 2 : 8,
          vertical: 16,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('设置',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          sectionHeader('通用'),
          ListTile(
            leading: const Icon(Icons.folder_rounded),
            title: const Text('下载位置'),
            subtitle: Text(settings.downloadDir,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing:
                Platform.isAndroid ? null : const Icon(Icons.chevron_right_rounded),
            onTap: Platform.isAndroid
                ? null
                : () async {
                    final dir = await getDirectoryPath();
                    if (dir != null) await settings.setDownloadDir(dir);
                  },
          ),
          ListTile(
            leading: const Icon(Icons.swap_vert_rounded),
            title: const Text('同时下载任务数'),
            trailing: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('1')),
                ButtonSegment(value: 2, label: Text('2')),
                ButtonSegment(value: 3, label: Text('3')),
                ButtonSegment(value: 4, label: Text('4')),
              ],
              selected: {settings.maxConcurrent},
              onSelectionChanged: (s) => settings.setMaxConcurrent(s.first),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode_rounded),
            title: const Text('外观'),
            trailing: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) => settings.setThemeMode(s.first),
            ),
          ),
          sectionHeader('网络'),
          ListTile(
            leading: const Icon(Icons.vpn_lock_rounded),
            title: const Text('代理'),
            subtitle: Text(settings.proxy.isEmpty
                ? '未设置（访问 YouTube / X 可能需要）'
                : settings.proxy),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _editText(
              context,
              title: '代理地址',
              hint: '例如 http://127.0.0.1:7890',
              initial: settings.proxy,
              onSave: settings.setProxy,
            ),
          ),
          if (!Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.cookie_rounded),
              title: const Text('浏览器 Cookie'),
              subtitle: const Text('下载 B 站大会员画质 / 会员内容时需要'),
              trailing: DropdownButton<String>(
                value: settings.cookiesBrowser.isEmpty
                    ? ''
                    : settings.cookiesBrowser,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: '', child: Text('不使用')),
                  DropdownMenuItem(value: 'chrome', child: Text('Chrome')),
                  DropdownMenuItem(value: 'edge', child: Text('Edge')),
                  DropdownMenuItem(value: 'firefox', child: Text('Firefox')),
                ],
                onChanged: (v) => settings.setCookiesBrowser(v ?? ''),
              ),
            ),
          sectionHeader('下载引擎'),
          if (!Platform.isAndroid) ...[
            ListTile(
              leading: const Icon(Icons.terminal_rounded),
              title: const Text('yt-dlp 路径'),
              subtitle: Text(settings.ytdlpPath),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _editText(
                context,
                title: 'yt-dlp 可执行文件路径',
                hint: '留空则使用 PATH 中的 yt-dlp',
                initial:
                    settings.ytdlpPath == 'yt-dlp' ? '' : settings.ytdlpPath,
                onSave: settings.setYtdlpPath,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.merge_rounded),
              title: const Text('FFmpeg 路径'),
              subtitle: Text(settings.ffmpegPath.isEmpty
                  ? '未设置（合并高清音视频时需要）'
                  : settings.ffmpegPath),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _editText(
                context,
                title: 'FFmpeg 所在目录',
                hint: '例如 C:\\ffmpeg\\bin',
                initial: settings.ffmpegPath,
                onSave: settings.setFfmpegPath,
              ),
            ),
          ] else
            const ListTile(
              leading: Icon(Icons.offline_bolt_rounded),
              title: Text('内置引擎'),
              subtitle: Text('yt-dlp 与 FFmpeg 已随应用打包，无需配置'),
            ),
          ListTile(
            leading: const Icon(Icons.health_and_safety_rounded),
            title: const Text('检查引擎状态'),
            subtitle: const Text('验证下载引擎是否可用'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final engine = context.read<VideoEngine>();
              try {
                final v = await engine.version();
                messenger.showSnackBar(
                    SnackBar(content: Text('引擎可用，yt-dlp 版本 $v')));
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('$e')));
              }
            },
          ),
          sectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline_rounded),
            title: Text('VDown'),
            subtitle: Text('v0.1.0 · 基于 Flutter 与 yt-dlp 构建\n'
                '请仅下载您拥有权利或获得授权的内容'),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded),
            title: const Text('yt-dlp 项目主页'),
            onTap: () => launchUrl(
                Uri.parse('https://github.com/yt-dlp/yt-dlp')),
          ),
        ],
      );
    });
  }

  Future<void> _editText(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    required Future<void> Function(String) onSave,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null) await onSave(result);
  }
}
