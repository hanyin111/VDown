import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// B 站官方 Web 扫码登录会话。
class BiliQrSession {
  final String url;
  final String qrcodeKey;

  const BiliQrSession({required this.url, required this.qrcodeKey});
}

enum BiliQrState { waitingScan, scannedWaitConfirm, expired, success, error }

class BiliQrPollResult {
  final BiliQrState state;
  final String message;
  final String? sessData;
  final String? cookieHeader;
  final String? username;

  const BiliQrPollResult({
    required this.state,
    required this.message,
    this.sessData,
    this.cookieHeader,
    this.username,
  });
}

class BiliResolvedStream {
  final String url;
  final Map<String, String> headers;

  const BiliResolvedStream({required this.url, required this.headers});
}

/// Bilibili 账号扫码登录与直播高画质（1080P 原画 / 蓝光 / 2K / 4K）直连解析服务。
///
/// B 站直播接口对未登录请求会在服务端强制限制最高 720P（qn=250），
/// 而新版 Windows Chrome/Edge 的 DPAPI v20 加密会导致 yt-dlp `--cookies-from-browser` 失败。
/// 本服务通过官方 Web 扫码登录获取 SESSDATA，并直连 `getRoomPlayInfo` 获取完整画质列表。
class BilibiliLiveService {
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static final RegExp _liveRoomRe = RegExp(
    r'https?://live\.bilibili\.com/(?:blanc/)?(\d+)',
    caseSensitive: false,
  );

  /// 常见 B 站直播 qn 与默认中文描述（若接口返回了 g_qn_desc 则优先使用接口描述）。
  static const Map<int, String> defaultQnNames = {
    30000: '杜比',
    20000: '4K',
    15000: '2K 极清',
    10000: '1080P 原画',
    400: '1080P 蓝光',
    250: '720P 超清',
    150: '480P 高清',
    80: '流畅',
  };

  static bool isBilibiliLiveUrl(String url) => _liveRoomRe.hasMatch(url.trim());

  static String? extractRoomId(String url) =>
      _liveRoomRe.firstMatch(url.trim())?.group(1);

  static HttpClient _createClient({String? proxy}) {
    final client = HttpClient();
    client.userAgent = userAgent;
    client.connectionTimeout = const Duration(seconds: 12);
    final p = (proxy ?? '').trim();
    if (p.isNotEmpty && p.toLowerCase().startsWith('http')) {
      final uri = Uri.tryParse(p);
      if (uri != null && uri.host.isNotEmpty && uri.port > 0) {
        client.findProxy = (_) => 'PROXY ${uri.host}:${uri.port}';
      }
    }
    return client;
  }

  static Future<(Map<String, dynamic>, List<Cookie>)> _getJson(
    String url, {
    Map<String, String> headers = const {},
    String? proxy,
  }) async {
    final client = _createClient(proxy: proxy);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      headers.forEach((k, v) {
        if (v.isNotEmpty) req.headers.set(k, v);
      });
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Bilibili API 返回格式无效');
      }
      return (decoded, resp.cookies);
    } finally {
      client.close(force: true);
    }
  }

  /// 生成 B 站官方 Web 登录二维码。
  static Future<BiliQrSession> generateQrCode({String? proxy}) async {
    final (json, _) = await _getJson(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
      proxy: proxy,
    );
    if (json['code'] != 0 || json['data'] is! Map) {
      throw Exception('生成二维码失败：${json['message'] ?? json['code']}');
    }
    final data = json['data'] as Map;
    return BiliQrSession(
      url: data['url']?.toString() ?? '',
      qrcodeKey: data['qrcode_key']?.toString() ?? '',
    );
  }

  /// 轮询扫码状态，登录成功后提取 `SESSDATA` 与用户名。
  static Future<BiliQrPollResult> pollQrStatus(
    String qrcodeKey, {
    String? proxy,
  }) async {
    final (json, cookies) = await _getJson(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=${Uri.encodeQueryComponent(qrcodeKey)}',
      proxy: proxy,
    );
    if (json['code'] != 0 || json['data'] is! Map) {
      return BiliQrPollResult(
        state: BiliQrState.error,
        message: '轮询失败：${json['message'] ?? json['code']}',
      );
    }
    final data = json['data'] as Map;
    final statusCode = (data['code'] as num?)?.toInt() ?? -1;
    switch (statusCode) {
      case 86101:
        return const BiliQrPollResult(
          state: BiliQrState.waitingScan,
          message: '请使用哔哩哔哩手机 App 扫描二维码',
        );
      case 86090:
        return const BiliQrPollResult(
          state: BiliQrState.scannedWaitConfirm,
          message: '已扫码，请在手机上点击「确认登录」',
        );
      case 86038:
        return const BiliQrPollResult(
          state: BiliQrState.expired,
          message: '二维码已失效，请刷新后重试',
        );
      case 0:
        final cookieMap = <String, String>{};
        for (final c in cookies) {
          if (c.value.isNotEmpty) {
            cookieMap[c.name] = c.value;
          }
        }
        // 备用：部分场景下回调 URL query 中也带有 SESSDATA
        final callbackUrl = data['url']?.toString() ?? '';
        final cbUri = Uri.tryParse(callbackUrl);
        if (cbUri != null) {
          for (final key in ['SESSDATA', 'bili_jct', 'DedeUserID']) {
            final v = cbUri.queryParameters[key];
            if (v != null && v.isNotEmpty && !cookieMap.containsKey(key)) {
              cookieMap[key] = v;
            }
          }
        }
        final sessData = cookieMap['SESSDATA'] ?? '';
        if (sessData.isEmpty) {
          return const BiliQrPollResult(
            state: BiliQrState.error,
            message: '登录成功但未获取到 SESSDATA，请重试或手动输入 Cookie',
          );
        }
        final cookieHeader = cookieMap.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
        final uname = await verifyCookie(cookieHeader, proxy: proxy);
        return BiliQrPollResult(
          state: BiliQrState.success,
          message: uname != null ? '已登录：$uname' : '登录成功',
          sessData: sessData,
          cookieHeader: cookieHeader,
          username: uname,
        );
      default:
        return BiliQrPollResult(
          state: BiliQrState.error,
          message: data['message']?.toString() ?? '状态码 $statusCode',
        );
    }
  }

  /// 验证 B 站 Cookie / SESSDATA 是否有效，有效时返回用户名。
  static Future<String?> verifyCookie(
    String cookieHeader, {
    String? proxy,
  }) async {
    final normalized = normalizeCookieHeader(cookieHeader);
    if (normalized.isEmpty) return null;
    try {
      final (json, _) = await _getJson(
        'https://api.bilibili.com/x/web-interface/nav',
        headers: {
          'Cookie': normalized,
          'Referer': 'https://www.bilibili.com/',
        },
        proxy: proxy,
      );
      if (json['code'] == 0 && json['data'] is Map) {
        final data = json['data'] as Map;
        if (data['isLogin'] == true) {
          return data['uname']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  /// 将纯 `SESSDATA` 值或完整 Cookie 字符串规范化为标准 HTTP Cookie 请求头。
  static String normalizeCookieHeader(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.contains('=')) {
      return 'SESSDATA=$trimmed';
    }
    return trimmed;
  }

  /// 解析并校验 B 站直播间全画质格式，返回与 `yt-dlp -J` 兼容的 JSON 字典。
  static Future<Map<String, dynamic>> fetchLiveInfoJson(
    String url, {
    String cookieHeader = '',
    String? proxy,
  }) async {
    final shortOrReal = extractRoomId(url);
    if (shortOrReal == null) {
      throw Exception('无效的 Bilibili 直播间链接');
    }

    final normCookie = normalizeCookieHeader(cookieHeader);
    final reqHeaders = <String, String>{
      'Referer': url,
      if (normCookie.isNotEmpty) 'Cookie': normCookie,
    };

    final (roomResp, _) = await _getJson(
      'https://api.live.bilibili.com/room/v1/Room/get_info?id=$shortOrReal',
      headers: reqHeaders,
      proxy: proxy,
    );
    if (roomResp['code'] != 0 || roomResp['data'] is! Map) {
      throw Exception('获取直播间信息失败：${roomResp['message'] ?? roomResp['code']}');
    }
    final roomData = roomResp['data'] as Map;
    if (roomData['live_status'] != 1) {
      throw Exception('该主播当前未开播，无法录制直播。');
    }

    final realRoomId = roomData['room_id']?.toString() ?? shortOrReal;
    final title = roomData['title']?.toString() ?? 'B站直播_$realRoomId';
    final cover = (roomData['user_cover'] ?? roomData['keyframe'])?.toString();

    // 先请求 qn=10000（原画），一次性拿到最高可用流与房间支持的全部分辨率描述表 g_qn_desc / accept_qn
    final firstPlay = await _fetchPlayInfo(
      realRoomId,
      10000,
      headers: reqHeaders,
      proxy: proxy,
    );

    final qnLabels = Map<int, String>.from(defaultQnNames);
    final playurl =
        (firstPlay['playurl_info'] as Map?)?['playurl'] as Map? ?? const {};
    final gQnDesc = playurl['g_qn_desc'] as List? ?? const [];
    for (final item in gQnDesc) {
      if (item is! Map) continue;
      final qn = (item['qn'] as num?)?.toInt();
      if (qn == null) continue;
      final label = _extractQnLabel(item);
      if (label.isNotEmpty) qnLabels[qn] = label;
    }

    final acceptQns = <int>{};
    final formats = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    var maxReturnedQn = 0;

    void collectFromPlayData(Map<String, dynamic> playData, int? targetQn) {
      final pu = (playData['playurl_info'] as Map?)?['playurl'] as Map?;
      final streams = pu?['stream'] as List? ?? const [];
      for (final st in streams) {
        if (st is! Map) continue;
        final fmts = st['format'] as List? ?? const [];
        for (final fmt in fmts) {
          if (fmt is! Map) continue;
          final fmtName = fmt['format_name']?.toString() ?? 'flv';
          final codecs = fmt['codec'] as List? ?? const [];
          for (final codec in codecs) {
            if (codec is! Map) continue;
            for (final aq in (codec['accept_qn'] as List? ?? const [])) {
              final q = (aq as num?)?.toInt();
              if (q != null && q > 0) acceptQns.add(q);
            }
            final curQn = (codec['current_qn'] as num?)?.toInt() ?? 0;
            if (curQn <= 0) continue;
            // 若指定了目标 qn 且服务商强制降级返回其它 qn，只收录匹配项或当前最高未收录档位
            if (targetQn != null && curQn != targetQn && seenIds.any((id) => id.startsWith('${curQn}_'))) {
              continue;
            }
            if (curQn > maxReturnedQn) maxReturnedQn = curQn;
            final codecName = codec['codec_name']?.toString() ?? 'avc';
            final baseUrl = codec['base_url']?.toString() ?? '';
            final urlInfos = codec['url_info'] as List? ?? const [];
            if (baseUrl.isEmpty || urlInfos.isEmpty) continue;

            final firstHost = urlInfos.first as Map;
            final streamUrl =
                '${firstHost['host'] ?? ''}$baseUrl${firstHost['extra'] ?? ''}';
            if (streamUrl.isEmpty) continue;

            final fid = '${curQn}_${fmtName}_$codecName';
            if (!seenIds.add(fid)) continue;

            final label = qnLabels[curQn] ?? '画质 $curQn';
            formats.add({
              'format_id': fid,
              'ext': fmtName == 'ts' ? 'ts' : (fmtName == 'fmp4' ? 'fmp4' : 'flv'),
              'vcodec': codecName,
              'acodec': 'aac',
              'format_note': label,
              'quality': curQn.toDouble(),
              'url': streamUrl,
              'http_headers': reqHeaders,
            });
          }
        }
      }
    }

    collectFromPlayData(firstPlay, null);

    // 并发补拉 accept_qn 中的其它档位（如 30000 杜比、20000 4K、15000 2K、400 蓝光、250 超清、150 高清、80 流畅）
    final extraQns = <int>{...acceptQns, 400, 250, 150, 80}
        .where((q) => !formats.any((f) => (f['format_id'] as String).startsWith('${q}_')))
        .toList();
    if (extraQns.isNotEmpty) {
      final results = await Future.wait(
        extraQns.map((q) async {
          try {
            final d = await _fetchPlayInfo(
              realRoomId,
              q,
              headers: reqHeaders,
              proxy: proxy,
            );
            return (q, d);
          } catch (_) {
            return null;
          }
        }),
      );
      for (final item in results) {
        if (item != null) {
          collectFromPlayData(item.$2, item.$1);
        }
      }
    }

    if (formats.isEmpty) {
      throw Exception('未获取到可用的 Bilibili 直播流地址。');
    }

    // 房间本身支持 >= 400（1080P 蓝光/原画），但返回最高流仅 <= 250（720P），通常因未登录 SESSDATA
    final maxAcceptedQn =
        acceptQns.isEmpty ? maxReturnedQn : acceptQns.reduce((a, b) => a > b ? a : b);
    final authLimited =
        normCookie.isEmpty && maxAcceptedQn >= 400 && maxReturnedQn <= 250;

    return {
      'id': realRoomId,
      'title': title,
      'thumbnail': cover,
      'uploader': '房间 $realRoomId',
      'webpage_url': url,
      'extractor_key': 'BiliLive',
      'is_live': true,
      'live_status': 'is_live',
      'http_headers': reqHeaders,
      'formats': formats,
      'bili_auth_limited': authLimited,
    };
  }

  /// 为桌面端 FFmpeg 直播录制快速匹配 `formatSelector` 对应的直连流与请求头。
  static Future<BiliResolvedStream?> resolveStreamForSelector(
    String url,
    String formatSelector, {
    String cookieHeader = '',
    String? proxy,
  }) async {
    final info = await fetchLiveInfoJson(
      url,
      cookieHeader: cookieHeader,
      proxy: proxy,
    );
    final rawFormats = (info['formats'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];
    if (rawFormats.isEmpty) return null;

    final primarySelector = formatSelector.split('/').first.trim();
    Map<String, dynamic>? picked;
    for (final f in rawFormats) {
      if (f['format_id']?.toString() == primarySelector) {
        picked = f;
        break;
      }
    }
    if (picked == null) {
      // 回退：按 quality 降序选最佳 AVC/fmp4 流
      final sorted = List<Map<String, dynamic>>.from(rawFormats)
        ..sort((a, b) {
          final qCmp = ((b['quality'] as num?) ?? 0)
              .compareTo((a['quality'] as num?) ?? 0);
          if (qCmp != 0) return qCmp;
          final aAvc = (a['vcodec']?.toString() ?? '').contains('avc') ? 1 : 0;
          final bAvc = (b['vcodec']?.toString() ?? '').contains('avc') ? 1 : 0;
          return bAvc.compareTo(aAvc);
        });
      picked = sorted.first;
    }

    final streamUrl = picked['url']?.toString() ?? '';
    if (streamUrl.isEmpty) return null;

    final headers = <String, String>{'User-Agent': userAgent};
    final rawHeaders = picked['http_headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k != null && v != null && v.toString().isNotEmpty) {
          headers[k.toString()] = v.toString();
        }
      });
    }
    return BiliResolvedStream(url: streamUrl, headers: headers);
  }

  static Future<Map<String, dynamic>> _fetchPlayInfo(
    String roomId,
    int qn, {
    required Map<String, String> headers,
    String? proxy,
  }) async {
    final url =
        'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo'
        '?room_id=$roomId&qn=$qn&codec=0,1&format=0,1,2&mask=0&no_playurl=0&platform=web&protocol=0,1';
    final (json, _) = await _getJson(url, headers: headers, proxy: proxy);
    if (json['code'] != 0 || json['data'] is! Map<String, dynamic>) {
      throw Exception('getRoomPlayInfo 失败：${json['message'] ?? json['code']}');
    }
    return json['data'] as Map<String, dynamic>;
  }

  static String _extractQnLabel(Map item) {
    final desc = item['desc']?.toString() ?? '';
    final mediaDesc = item['media_base_desc'];
    if (mediaDesc is Map) {
      final detail = mediaDesc['detail_desc'];
      if (detail is Map && detail['desc'] != null) {
        final d = detail['desc'].toString().trim();
        if (d.isNotEmpty) return d;
      }
      final brief = mediaDesc['brief_desc'];
      if (brief is Map && brief['desc'] != null) {
        final b = brief['desc'].toString().trim();
        if (b.isNotEmpty && desc.isNotEmpty) {
          return '$b $desc';
        }
      }
    }
    final qn = (item['qn'] as num?)?.toInt();
    if (qn != null && defaultQnNames.containsKey(qn)) {
      return defaultQnNames[qn]!;
    }
    return desc;
  }
}
