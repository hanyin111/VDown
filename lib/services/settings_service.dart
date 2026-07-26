import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局设置，持久化到 SharedPreferences。
class SettingsService extends ChangeNotifier {
  static const _kDownloadDir = 'downloadDir';
  static const _kYtdlpPath = 'ytdlpPath';
  static const _kFfmpegPath = 'ffmpegPath';
  static const _kProxy = 'proxy';
  static const _kCookiesBrowser = 'cookiesBrowser';
  static const _kMaxConcurrent = 'maxConcurrent';
  static const _kThemeMode = 'themeMode';

  late final SharedPreferences _prefs;

  String downloadDir = '';
  String ytdlpPath = 'yt-dlp';
  String ffmpegPath = '';
  String proxy = '';

  /// 从哪个浏览器读取 Cookie（B 站大会员 / 私享视频需要）。空串表示不用。
  String cookiesBrowser = '';
  int maxConcurrent = 2;
  ThemeMode themeMode = ThemeMode.system;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    downloadDir = _prefs.getString(_kDownloadDir) ?? await _defaultDownloadDir();
    ytdlpPath = _prefs.getString(_kYtdlpPath) ?? 'yt-dlp';
    ffmpegPath = _prefs.getString(_kFfmpegPath) ?? '';
    proxy = _prefs.getString(_kProxy) ?? '';
    cookiesBrowser = _prefs.getString(_kCookiesBrowser) ?? '';
    maxConcurrent = _prefs.getInt(_kMaxConcurrent) ?? 2;
    themeMode = ThemeMode
        .values[_prefs.getInt(_kThemeMode) ?? ThemeMode.system.index];
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
    await _prefs.setString(_kDownloadDir, v);
    notifyListeners();
  }

  Future<void> setYtdlpPath(String v) async {
    ytdlpPath = v.trim().isEmpty ? 'yt-dlp' : v.trim();
    await _prefs.setString(_kYtdlpPath, ytdlpPath);
    notifyListeners();
  }

  Future<void> setFfmpegPath(String v) async {
    ffmpegPath = v.trim();
    await _prefs.setString(_kFfmpegPath, ffmpegPath);
    notifyListeners();
  }

  Future<void> setProxy(String v) async {
    proxy = v.trim();
    await _prefs.setString(_kProxy, proxy);
    notifyListeners();
  }

  Future<void> setCookiesBrowser(String v) async {
    cookiesBrowser = v;
    await _prefs.setString(_kCookiesBrowser, v);
    notifyListeners();
  }

  Future<void> setMaxConcurrent(int v) async {
    maxConcurrent = v;
    await _prefs.setInt(_kMaxConcurrent, v);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode v) async {
    themeMode = v;
    await _prefs.setInt(_kThemeMode, v.index);
    notifyListeners();
  }

  /// 所有 yt-dlp 调用共用的网络参数。
  List<String> get commonNetworkArgs => [
        if (proxy.isNotEmpty) ...['--proxy', proxy],
        if (cookiesBrowser.isNotEmpty) ...[
          '--cookies-from-browser',
          cookiesBrowser,
        ],
      ];
}
