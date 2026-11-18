import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/bilibili_live_service.dart';
import '../../services/settings_service.dart';

/// B 站账号登录弹窗：支持官方手机扫码登录（推荐，不受系统浏览器加密限制）或手动填入 SESSDATA。
class BiliLoginDialog extends StatefulWidget {
  const BiliLoginDialog({super.key});

  /// 弹出登录框，登录成功返回 true，否则返回 false。
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const BiliLoginDialog(),
    );
    return result == true;
  }

  @override
  State<BiliLoginDialog> createState() => _BiliLoginDialogState();
}

class _BiliLoginDialogState extends State<BiliLoginDialog> {
  bool _manualMode = false;
  bool _loadingQr = true;
  bool _submittingManual = false;
  String? _qrError;
  BiliQrSession? _session;
  String _statusText = '正在获取登录二维码…';
  Timer? _pollTimer;
  final _cookieController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    if (settings.biliSessData.isNotEmpty) {
      _cookieController.text = settings.biliSessData;
    }
    _initQr();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _initQr() async {
    _pollTimer?.cancel();
    setState(() {
      _loadingQr = true;
      _qrError = null;
      _session = null;
      _statusText = '正在获取登录二维码…';
    });
    final proxy = context.read<SettingsService>().proxy;
    try {
      final session = await BilibiliLiveService.generateQrCode(proxy: proxy);
      if (!mounted) return;
      setState(() {
        _session = session;
        _loadingQr = false;
        _statusText = '请使用哔哩哔哩手机 App 扫描二维码';
      });
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingQr = false;
        _qrError = '生成二维码失败：$e';
      });
    }
  }

  Future<void> _poll() async {
    final session = _session;
    if (session == null || _manualMode) return;
    final settings = context.read<SettingsService>();
    final res = await BilibiliLiveService.pollQrStatus(
      session.qrcodeKey,
      proxy: settings.proxy,
    );
    if (!mounted) return;

    setState(() => _statusText = res.message);

    if (res.state == BiliQrState.expired) {
      _pollTimer?.cancel();
      setState(() => _qrError = res.message);
    } else if (res.state == BiliQrState.success && res.sessData != null) {
      _pollTimer?.cancel();
      await settings.setBiliAuth(
        sessData: res.sessData!,
        cookieHeader: res.cookieHeader ?? '',
        username: res.username ?? '',
      );
      if (mounted) Navigator.pop(context, true);
    } else if (res.state == BiliQrState.error) {
      _pollTimer?.cancel();
      setState(() => _qrError = res.message);
    }
  }

  Future<void> _saveManual() async {
    final raw = _cookieController.text.trim();
    if (raw.isEmpty) return;
    setState(() => _submittingManual = true);
    final settings = context.read<SettingsService>();
    final normalized = BilibiliLiveService.normalizeCookieHeader(raw);
    final uname =
        await BilibiliLiveService.verifyCookie(normalized, proxy: settings.proxy);
    if (!mounted) return;

    final sessMatch = RegExp(r'SESSDATA=([^;\s]+)').firstMatch(normalized);
    final sess = sessMatch?.group(1) ?? raw;
    await settings.setBiliAuth(
      sessData: sess,
      cookieHeader: normalized,
      username: uname ?? '',
    );
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('登录哔哩哔哩解锁 1080P+'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('手机扫码登录')),
                ButtonSegment(value: true, label: Text('手动填 SESSDATA')),
              ],
              selected: {_manualMode},
              onSelectionChanged: (s) {
                setState(() => _manualMode = s.first);
                if (!_manualMode && _session == null) {
                  _initQr();
                }
              },
            ),
            const SizedBox(height: 16),
            if (!_manualMode) ...[
              if (_loadingQr)
                const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_qrError != null)
                SizedBox(
                  height: 200,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code_2_rounded,
                          size: 48, color: scheme.error),
                      const SizedBox(height: 8),
                      Text(_qrError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: _initQr,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('刷新二维码'),
                      ),
                    ],
                  ),
                )
              else if (_session != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: _session!.url,
                    version: QrVersions.auto,
                    size: 184,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ] else ...[
              TextField(
                controller: _cookieController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'SESSDATA 或完整 Cookie 串',
                  hintText: '粘贴浏览器中的 SESSDATA 值（可解 1080P 原画/蓝光/大会员）',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '提示：在浏览器打开 live.bilibili.com 按 F12 → Application/存储 → Cookies 中复制 SESSDATA 即可，凭据仅保存在本机。',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('关闭'),
        ),
        if (_manualMode)
          FilledButton(
            onPressed: _submittingManual ? null : _saveManual,
            child: Text(_submittingManual ? '验证中…' : '保存登录'),
          ),
      ],
    );
  }
}
