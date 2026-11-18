import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bilibili_live_service.dart';

/// 全局设置，持久化到 SharedPreferences。
class SettingsService extends ChangeNotifier {
  static const _kDownloadDir = 'downloadDir';
  static const _kYtdlpPath = 'ytdlpPath';
  static const _kFfmpegPath = 'ffmpegPath';
  static const _kProxy = 'proxy';
  static const _kCookiesBrowser = 'cookiesBrowser';
  static const _kCookiesFilePath = 'cookiesFilePath';
  static const _kBiliSessData = 'biliSessData';
  static const _kBiliCookieHeader = 'biliCookieHeader';
  static const _kBiliUserName = 'biliUserName';
  static const _kMaxConcurrent = 'maxConcurrent';
  static const _kThemeMode = 'themeMode';

  SharedPreferences? _prefs;

  String downloadDir = '';
  String ytdlpPath = 'yt-dlp';
  String ffmpegPath = '';
  String proxy = '';

  /// 从哪个浏览器读取 Cookie（B 站大会员 / 私享视频需要）。空串表示不用。
  String cookiesBrowser = '';
  String cookiesFilePath = '';
  String biliSessData = '';
  String biliCookieHeader = '';
  String biliUserName = '';
  int maxConcurrent = 2;
  ThemeMode themeMode = ThemeMode.system;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    downloadDir = _prefs!.getString(_kDownloadDir) ?? await _defaultDownloadDir();
    ytdlpPath = _prefs!.getString(_kYtdlpPath) ?? 'yt-dlp';
    ffmpegPath = _prefs!.getString(_kFfmpegPath) ?? '';
    proxy = _prefs!.getString(_kProxy) ?? '';
    cookiesBrowser = _prefs!.getString(_kCookiesBrowser) ?? '';
    cookiesFilePath = _prefs!.getString(_kCookiesFilePath) ?? '';
    biliSessData = _prefs!.getString(_kBiliSessData) ?? '';
    biliCookieHeader = _prefs!.getString(_kBiliCookieHeader) ?? '';
    biliUserName = _prefs!.getString(_kBiliUserName) ?? '';
    maxConcurrent = _prefs!.getInt(_kMaxConcurrent) ?? 2;
    themeMode = ThemeMode
        .values[_prefs!.getInt(_kThemeMode) ?? ThemeMode.system.index];
    notifyListeners();
  }

  Future<String> _defaultDownloadDir() async {
    // Android 11+ 允许应用直接在公共下载目录创建自己的文件。
    if (Platform.isAndroid) return '/storage/emulated/0/Download/VDown';
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir.path;
    } catch (_) {}
    return Directory.current.path;
  }

  Future<void> setDownloadDir(String v) async {
    downloadDir = v;
    await _prefs?.setString(_kDownloadDir, v);
    notifyListeners();
  }

  Future<void> setYtdlpPath(String v) async {
    ytdlpPath = v.trim().isEmpty ? 'yt-dlp' : v.trim();
    await _prefs?.setString(_kYtdlpPath, ytdlpPath);
    notifyListeners();
  }

  Future<void> setFfmpegPath(String v) async {
    ffmpegPath = v.trim();
    await _prefs?.setString(_kFfmpegPath, ffmpegPath);
    notifyListeners();
  }

  Future<void> setProxy(String v) async {
    proxy = v.trim();
    await _prefs?.setString(_kProxy, proxy);
    notifyListeners();
  }

  Future<void> setCookiesBrowser(String v) async {
    cookiesBrowser = v;
    await _prefs?.setString(_kCookiesBrowser, v);
    notifyListeners();
  }

  Future<void> setCookiesFilePath(String v) async {
    cookiesFilePath = v.trim();
    await _prefs?.setString(_kCookiesFilePath, cookiesFilePath);
    notifyListeners();
  }

  Future<void> setBiliAuth({
    required String sessData,
    String cookieHeader = '',
    String username = '',
  }) async {
    biliSessData = sessData.trim();
    biliCookieHeader = cookieHeader.trim().isNotEmpty
        ? cookieHeader.trim()
        : BilibiliLiveService.normalizeCookieHeader(biliSessData);
    biliUserName = username.trim();
    await _prefs?.setString(_kBiliSessData, biliSessData);
    await _prefs?.setString(_kBiliCookieHeader, biliCookieHeader);
    await _prefs?.setString(_kBiliUserName, biliUserName);
    notifyListeners();
  }

  Future<void> clearBiliAuth() async {
    biliSessData = '';
    biliCookieHeader = '';
    biliUserName = '';
    await _prefs?.remove(_kBiliSessData);
    await _prefs?.remove(_kBiliCookieHeader);
    await _prefs?.remove(_kBiliUserName);
    notifyListeners();
  }

  Future<void> setMaxConcurrent(int v) async {
    maxConcurrent = v;
    await _prefs?.setInt(_kMaxConcurrent, v);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode v) async {
    themeMode = v;
    await _prefs?.setInt(_kThemeMode, v.index);
    notifyListeners();
  }

  bool get hasBiliAuth => effectiveBiliCookieHeader.isNotEmpty;

  /// 用于 B 站直连 API 与直播流解析的 Cookie 请求头。
  String get effectiveBiliCookieHeader {
    if (biliCookieHeader.trim().isNotEmpty) {
      return BilibiliLiveService.normalizeCookieHeader(biliCookieHeader);
    }
    if (biliSessData.trim().isNotEmpty) {
      return BilibiliLiveService.normalizeCookieHeader(biliSessData);
    }
    if (cookiesFilePath.isNotEmpty && File(cookiesFilePath).existsSync()) {
      return _extractBiliCookiesFromNetscape(File(cookiesFilePath).readAsStringSync());
    }
    return '';
  }

  static String _extractBiliCookiesFromNetscape(String content) {
    final pairs = <String>[];
    for (final line in content.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final cols = trimmed.split('\t');
      if (cols.length >= 7 && cols[0].contains('bilibili.com')) {
        pairs.add('${cols[5]}=${cols[6]}');
      }
    }
    return pairs.join('; ');
  }

  /// 生成供 yt-dlp `--cookies` 使用的 Netscape Cookie 文件（优先用户导入的 cookies.txt，其次已登录 B 站凭据）。
  Future<String?> ensureEffectiveCookiesFile() async {
    if (cookiesFilePath.isNotEmpty && File(cookiesFilePath).existsSync()) {
      return cookiesFilePath;
    }
    final raw = effectiveBiliCookieHeader;
    if (raw.isEmpty) return null;

    final dir = await getTemporaryDirectory();
    final cookieFile =
        File('${dir.path}${Platform.pathSeparator}vdown_bili_cookies.txt');
    final buf = StringBuffer()
      ..writeln('# Netscape HTTP Cookie File')
      ..writeln('# Generated by VDown');
    for (final part in raw.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim();
      final val = part.substring(eq + 1).trim();
      if (name.isEmpty || val.isEmpty) continue;
      buf.writeln('.bilibili.com\tTRUE\t/\tFALSE\t2147483647\t$name\t$val');
    }
    await cookieFile.writeAsString(buf.toString(), flush: true);
    return cookieFile.path;
  }

  /// 异步解析 yt-dlp 共用网络参数（优先使用 cookies.txt / B 站登录 Cookie，避免 Windows DPAPI 失败）。
  Future<List<String>> resolveNetworkArgs() async {
    final cookiesFile = await ensureEffectiveCookiesFile();
    return [
      if (proxy.isNotEmpty) ...['--proxy', proxy],
      if (cookiesFile != null) ...[
        '--cookies',
        cookiesFile,
      ] else if (cookiesBrowser.isNotEmpty) ...[
        '--cookies-from-browser',
        cookiesBrowser,
      ],
    ];
  }

  /// 所有 yt-dlp 调用共用的同步网络参数。
  List<String> get commonNetworkArgs => [
        if (proxy.isNotEmpty) ...['--proxy', proxy],
        if (cookiesFilePath.isNotEmpty && File(cookiesFilePath).existsSync()) ...[
          '--cookies',
          cookiesFilePath,
        ] else if (cookiesBrowser.isNotEmpty) ...[
          '--cookies-from-browser',
          cookiesBrowser,
        ],
      ];
}
