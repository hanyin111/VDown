import { http } from '@kit.NetworkKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  AppSettingsModel,
  DownloadTaskModel,
  formatBytes,
  formatDuration,
  TaskStatus,
  VideoFormatModel,
  VideoInfoModel
} from '../models/VDownModels';

const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

interface BiliRoomInfoData {
  room_id?: number;
  uid?: number;
  title?: string;
  live_status?: number;
  user_cover?: string;
  keyframe?: string;
}

interface BiliRoomInfoResp {
  code?: number;
  message?: string;
  data?: BiliRoomInfoData;
}

interface BiliUrlInfoItem {
  host?: string;
  extra?: string;
}

interface BiliCodecItem {
  codec_name?: string;
  current_qn?: number;
  base_url?: string;
  url_info?: BiliUrlInfoItem[];
}

interface BiliFormatItem {
  format_name?: string;
  codec?: BiliCodecItem[];
}

interface BiliStreamItem {
  protocol_name?: string;
  format?: BiliFormatItem[];
}

interface BiliPlayurlInfo {
  playurl?: BiliPlayurlInner;
}

interface BiliPlayurlInner {
  stream?: BiliStreamItem[];
}

interface BiliRoomPlayData {
  room_id?: number;
  playurl_info?: BiliPlayurlInfo;
}

interface BiliRoomPlayResp {
  code?: number;
  message?: string;
  data?: BiliRoomPlayData;
}

interface BiliOwner {
  name?: string;
}

interface BiliPageItem {
  cid?: number;
  duration?: number;
}

interface BiliViewData {
  bvid?: string;
  title?: string;
  pic?: string;
  duration?: number;
  cid?: number;
  owner?: BiliOwner;
  pages?: BiliPageItem[];
}

interface BiliViewResp {
  code?: number;
  message?: string;
  data?: BiliViewData;
}

interface BiliDurlItem {
  url?: string;
  size?: number;
}

interface BiliVodPlayData {
  accept_quality?: number[];
  accept_description?: string[];
  durl?: BiliDurlItem[];
}

interface BiliVodPlayResp {
  code?: number;
  message?: string;
  data?: BiliVodPlayData;
}

interface BridgeFormatJson {
  format_id?: string;
  ext?: string;
  height?: number;
  fps?: number;
  vcodec?: string;
  acodec?: string;
  filesize?: number;
  tbr?: number;
  format_note?: string;
  quality?: number;
  display_label?: string;
}

interface BridgeInfoJson {
  id?: string;
  title?: string;
  uploader?: string;
  thumbnail?: string;
  duration?: number;
  webpage_url?: string;
  extractor?: string;
  is_live?: boolean;
  is_youtube?: boolean;
  formats?: BridgeFormatJson[];
  error?: string;
}

interface BridgeStartJson {
  task_id?: string;
  error?: string;
}

interface BridgeStatusJson {
  status?: string;
  progress?: number;
  recorded_duration?: string;
  recorded_size?: string;
  bitrate?: string;
  speed?: string;
  total_size?: string;
  segment_index?: number;
  saved_files?: string[];
  output_file?: string;
  error?: string;
}

interface BridgeSplitJson {
  saved_file?: string;
  error?: string;
}

interface LiveSessionControl {
  stopMode: string;
  activeReq: http.HttpRequest | null;
  splitWaiter: ((path: string | null) => void) | null;
}

interface FlvHeaderCapture {
  bytes: Uint8Array;
  done: boolean;
}

class BiliLiveQn {
  qn: number;
  id: string;
  label: string;

  constructor(qn: number, id: string, label: string) {
    this.qn = qn;
    this.id = id;
    this.label = label;
  }
}

const BILI_LIVE_QNS: BiliLiveQn[] = [
  new BiliLiveQn(30000, 'dolby', '杜比'),
  new BiliLiveQn(20000, '4K', '4K'),
  new BiliLiveQn(15000, '2k', '2K 极清'),
  new BiliLiveQn(10000, 'source', '1080P 原画'),
  new BiliLiveQn(400, 'blue_ray', '1080P 蓝光'),
  new BiliLiveQn(250, 'ultra_high_res', '720P 超清'),
  new BiliLiveQn(150, 'high_res', '480P 高清'),
  new BiliLiveQn(80, 'low', '流畅')
];

export class VDownEngine {
  private sessions: Map<string, LiveSessionControl> = new Map();

  async parseVideo(rawUrl: string, settings: AppSettingsModel): Promise<VideoInfoModel> {
    const url = await this.resolveShortUrl(rawUrl.trim());
    const isYouTube = url.includes('youtube.com') || url.includes('youtu.be');
    const isBiliLive = /https?:\/\/live\.bilibili\.com\/(?:blanc\/)?(\d+)/.test(url);
    const isBiliVod = /bilibili\.com\/video\/(BV[0-9A-Za-z]+|av\d+)/i.test(url);

    // 若配置了桌面协同服务，YouTube 与通用站优先走协同服务（支持 YouTube 全画质 + 直播断点录制）
    const bridge = settings.bridgeUrl.trim().replace(/\/+$/, '');
    if (bridge.length > 0 && (isYouTube || (!isBiliLive && !isBiliVod && !this.isDirectMediaUrl(url)))) {
      return await this.parseViaBridge(bridge, url);
    }

    if (isBiliLive) {
      return await this.parseBiliLive(url, settings);
    }

    if (isBiliVod) {
      return await this.parseBiliVod(url, settings);
    }

    if (this.isDirectMediaUrl(url)) {
      return this.buildDirectMediaInfo(url);
    }

    if (isYouTube) {
      throw new Error(
        'YouTube 视频与直播需要 JS 签名与 FFmpeg 实时混流。\n' +
        '请在「设置 → 协同录制服务地址」填入电脑端 VDown 桥接服务地址（如 http://192.168.x.x:8765）即可解锁 YouTube 直播实时录制与任意时刻断点保存。'
      );
    }

    throw new Error('暂不支持直接解析该站点，请在「设置」配置 VDown 协同录制服务以支持 1800+ 网站。');
  }

  private isDirectMediaUrl(url: string): boolean {
    const lower = url.toLowerCase();
    return lower.includes('.m3u8') || lower.includes('.flv') || lower.includes('.mp4');
  }

  private buildDirectMediaInfo(url: string): VideoInfoModel {
    const info = new VideoInfoModel();
    const isM3u8 = url.toLowerCase().includes('.m3u8');
    const isFlv = url.toLowerCase().includes('.flv');
    info.id = `${Date.now()}`;
    info.title = isM3u8 ? 'HLS 直播/媒体流' : (isFlv ? 'FLV 直播流' : '直链 MP4 视频');
    info.uploader = '直连媒体';
    info.webpageUrl = url;
    info.extractor = 'DirectStream';
    info.isLive = isM3u8 || isFlv;

    const fmt = new VideoFormatModel();
    fmt.formatId = 'direct';
    fmt.ext = isM3u8 ? 'ts' : (isFlv ? 'flv' : 'mp4');
    fmt.formatNote = info.isLive ? '直播原画流' : '直连画质';
    fmt.streamUrl = url;
    fmt.isHls = isM3u8;
    fmt.userAgent = DEFAULT_UA;
    info.formats = [fmt];
    return info;
  }

  private async resolveShortUrl(url: string): Promise<string> {
    if (!url.includes('b23.tv')) {
      return url;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': DEFAULT_UA },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 10000
      });
      const locObj = Reflect.get(resp.header as Object, 'location') as string | undefined;
      const locUpper = Reflect.get(resp.header as Object, 'Location') as string | undefined;
      const loc = locObj ?? locUpper ?? '';
      if (loc.startsWith('http')) {
        return loc;
      }
      const resultStr = typeof resp.result === 'string' ? resp.result : '';
      const bvMatch = resultStr.match(/https?:\/\/(?:www\.)?bilibili\.com\/video\/BV[0-9A-Za-z]+/);
      return bvMatch ? bvMatch[0] : url;
    } catch (_err) {
      return url;
    } finally {
      req.destroy();
    }
  }

  private async parseBiliLive(url: string, settings: AppSettingsModel): Promise<VideoInfoModel> {
    const match = url.match(/https?:\/\/live\.bilibili\.com\/(?:blanc\/)?(\d+)/);
    if (!match || match.length < 2) {
      throw new Error('无效的 Bilibili 直播间链接');
    }
    const roomId = match[1];
    const headers: Record<string, string> = {
      'User-Agent': DEFAULT_UA,
      'Referer': url
    };
    if (settings.biliSessData.trim().length > 0) {
      headers['Cookie'] = `SESSDATA=${settings.biliSessData.trim()}`;
    }

    const roomJson = await this.getJson<BiliRoomInfoResp>(
      `https://api.live.bilibili.com/room/v1/Room/get_info?id=${roomId}`,
      headers
    );
    if (roomJson.code !== 0 || !roomJson.data) {
      throw new Error(`获取直播间信息失败：${roomJson.message ?? '未知错误'}`);
    }
    if (roomJson.data.live_status !== 1) {
      throw new Error('该主播当前未开播，无法录制直播。');
    }

    const realRoomId = `${roomJson.data.room_id ?? roomId}`;
    const info = new VideoInfoModel();
    info.id = realRoomId;
    info.title = roomJson.data.title ?? `B站直播_${realRoomId}`;
    info.uploader = `房间 ${realRoomId}`;
    info.thumbnail = roomJson.data.user_cover ?? roomJson.data.keyframe ?? '';
    info.webpageUrl = url;
    info.extractor = 'BiliLive';
    info.isLive = true;

    const formats: VideoFormatModel[] = [];
    for (let i = 0; i < BILI_LIVE_QNS.length; i++) {
      const qnItem = BILI_LIVE_QNS[i];
      try {
        const playUrl =
          `https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo` +
          `?room_id=${realRoomId}&qn=${qnItem.qn}&codec=0,1&format=0,1,2&mask=0&no_playurl=0&platform=web&protocol=0,1`;
        const playResp = await this.getJson<BiliRoomPlayResp>(playUrl, headers);
        const streams: BiliStreamItem[] = playResp.data?.playurl_info?.playurl?.stream ?? [];
        const picked = this.pickBestBiliLiveFormat(streams, qnItem, url, settings.preferFmp4Live);
        if (picked) {
          formats.push(picked);
        }
      } catch (_err) {
        // 某些画质档位可能不存在，跳过
      }
    }

    if (formats.length === 0) {
      throw new Error('未获取到可用的 Bilibili 直播流地址。');
    }
    info.formats = formats;
    return info;
  }

  private pickBestBiliLiveFormat(
    streams: BiliStreamItem[],
    qnItem: BiliLiveQn,
    referer: string,
    preferFmp4: boolean
  ): VideoFormatModel | null {
    let best: VideoFormatModel | null = null;
    let bestScore = -1;

    for (let sIdx = 0; sIdx < streams.length; sIdx++) {
      const stream = streams[sIdx];
      const proto = stream.protocol_name ?? '';
      const fmts = stream.format ?? [];
      for (let fIdx = 0; fIdx < fmts.length; fIdx++) {
        const fmt = fmts[fIdx];
        const fmtName = fmt.format_name ?? '';
        const codecs = fmt.codec ?? [];
        for (let cIdx = 0; cIdx < codecs.length; cIdx++) {
          const codec = codecs[cIdx];
          if (codec.current_qn !== qnItem.qn) {
            continue;
          }
          const urlInfos = codec.url_info ?? [];
          if (urlInfos.length === 0 || !codec.base_url) {
            continue;
          }
          const firstHost = urlInfos[0];
          const fullUrl = `${firstHost.host ?? ''}${codec.base_url}${firstHost.extra ?? ''}`;
          if (!fullUrl.startsWith('http')) {
            continue;
          }

          let score = 0;
          if ((codec.codec_name ?? '').toLowerCase().includes('avc')) {
            score += 4;
          }
          const isHls = proto === 'http_hls' || fullUrl.includes('.m3u8');
          if (preferFmp4 && isHls && (fmtName === 'fmp4' || fmtName === 'ts')) {
            score += 20;
          } else if (!preferFmp4 && fmtName === 'flv') {
            score += 20;
          } else if (fmtName === 'fmp4') {
            score += 10;
          } else if (fmtName === 'ts') {
            score += 8;
          } else if (fmtName === 'flv') {
            score += 6;
          }

          if (score > bestScore) {
            bestScore = score;
            const model = new VideoFormatModel();
            model.formatId = qnItem.id;
            model.formatNote = `${qnItem.label}${isHls ? ' · HLS' : ' · FLV'}`;
            model.ext = isHls ? (fmtName === 'fmp4' ? 'mp4' : 'ts') : 'flv';
            model.vcodec = codec.codec_name ?? 'avc';
            model.acodec = 'aac';
            model.quality = qnItem.qn;
            model.streamUrl = fullUrl;
            model.referer = referer;
            model.userAgent = DEFAULT_UA;
            model.isHls = isHls;
            best = model;
          }
        }
      }
    }
    return best;
  }

  private async parseBiliVod(url: string, settings: AppSettingsModel): Promise<VideoInfoModel> {
    const bvMatch = url.match(/(BV[0-9A-Za-z]+)/);
    if (!bvMatch || bvMatch.length < 2) {
      throw new Error('请提供包含 BV 号的 Bilibili 视频链接。');
    }
    const bvid = bvMatch[1];
    const headers: Record<string, string> = {
      'User-Agent': DEFAULT_UA,
      'Referer': 'https://www.bilibili.com/'
    };
    if (settings.biliSessData.trim().length > 0) {
      headers['Cookie'] = `SESSDATA=${settings.biliSessData.trim()}`;
    }

    const viewResp = await this.getJson<BiliViewResp>(
      `https://api.bilibili.com/x/web-interface/view?bvid=${bvid}`,
      headers
    );
    if (viewResp.code !== 0 || !viewResp.data) {
      throw new Error(`解析 B 站视频失败：${viewResp.message ?? '未知错误'}`);
    }
    const vd = viewResp.data;
    const cid = vd.cid ?? (vd.pages && vd.pages.length > 0 ? vd.pages[0].cid ?? 0 : 0);

    const info = new VideoInfoModel();
    info.id = vd.bvid ?? bvid;
    info.title = vd.title ?? 'Bilibili 视频';
    info.uploader = vd.owner?.name ?? 'Bilibili UP 主';
    info.thumbnail = vd.pic ?? '';
    info.durationSeconds = vd.duration ?? 0;
    info.webpageUrl = `https://www.bilibili.com/video/${info.id}`;
    info.extractor = 'BiliBili';
    info.isLive = false;

    const formats: VideoFormatModel[] = [];
    const qns = [80, 64, 32, 16];
    const qnNames: Map<number, string> = new Map<number, string>([
      [80, '1080P'],
      [64, '720P'],
      [32, '480P'],
      [16, '360P']
    ]);
    const qnHeights: Map<number, number> = new Map<number, number>([
      [80, 1080],
      [64, 720],
      [32, 480],
      [16, 360]
    ]);

    for (let i = 0; i < qns.length; i++) {
      const qn = qns[i];
      try {
        const playResp = await this.getJson<BiliVodPlayResp>(
          `https://api.bilibili.com/x/player/playurl?bvid=${info.id}&cid=${cid}&qn=${qn}&fnval=1&platform=html5&high_quality=1`,
          headers
        );
        const durl = playResp.data?.durl ?? [];
        if (durl.length > 0 && durl[0].url) {
          const fmt = new VideoFormatModel();
          fmt.formatId = `${qn}`;
          fmt.ext = 'mp4';
          fmt.height = qnHeights.get(qn) ?? 720;
          fmt.formatNote = qnNames.get(qn) ?? `${qn}`;
          fmt.vcodec = 'h264';
          fmt.acodec = 'aac';
          fmt.filesize = durl[0].size ?? 0;
          fmt.streamUrl = durl[0].url!;
          fmt.referer = 'https://www.bilibili.com/';
          fmt.userAgent = DEFAULT_UA;
          formats.push(fmt);
        }
      } catch (_err) {
        // skip unavailable quality
      }
    }

    if (formats.length === 0) {
      throw new Error('未能获取到该视频的可直连 MP4 流。');
    }
    info.formats = formats;
    return info;
  }

  private async parseViaBridge(bridgeUrl: string, url: string): Promise<VideoInfoModel> {
    const resp = await this.postJson<BridgeInfoJson>(`${bridgeUrl}/api/info`, JSON.stringify({ url: url }));
    if (resp.error) {
      throw new Error(resp.error);
    }
    const info = new VideoInfoModel();
    info.id = resp.id ?? '';
    info.title = resp.title ?? '未命名视频';
    info.uploader = resp.uploader ?? '';
    info.thumbnail = resp.thumbnail ?? '';
    info.durationSeconds = resp.duration ?? 0;
    info.webpageUrl = resp.webpage_url ?? url;
    info.extractor = resp.extractor ?? 'yt-dlp Bridge';
    info.isLive = resp.is_live ?? false;
    info.isYouTube = resp.is_youtube ?? (url.includes('youtube.com') || url.includes('youtu.be'));
    info.viaBridge = true;

    const fmts: VideoFormatModel[] = [];
    const rawFmts = resp.formats ?? [];
    for (let i = 0; i < rawFmts.length; i++) {
      const f = rawFmts[i];
      const m = new VideoFormatModel();
      m.formatId = f.format_id ?? '';
      m.ext = f.ext ?? 'mp4';
      m.height = f.height ?? 0;
      m.fps = f.fps ?? 0;
      m.vcodec = f.vcodec ?? '';
      m.acodec = f.acodec ?? '';
      m.filesize = f.filesize ?? 0;
      m.tbr = f.tbr ?? 0;
      m.formatNote = f.display_label ?? f.format_note ?? f.format_id ?? '';
      m.quality = f.quality ?? 0;
      fmts.push(m);
    }
    info.formats = fmts;
    return info;
  }

  async runTask(
    task: DownloadTaskModel,
    settings: AppSettingsModel,
    filesDir: string,
    onUpdate: () => void
  ): Promise<void> {
    if (task.viaBridge && settings.bridgeUrl.trim().length > 0) {
      await this.runViaBridge(task, settings.bridgeUrl.trim().replace(/\/+$/, ''), filesDir, onUpdate);
      return;
    }

    if (task.isLive) {
      if (task.isHls) {
        await this.recordHlsLive(task, settings, filesDir, onUpdate);
      } else {
        await this.recordFlvLive(task, settings, filesDir, onUpdate);
      }
      return;
    }

    await this.downloadVodStream(task, settings, filesDir, onUpdate);
  }

  private async downloadVodStream(
    task: DownloadTaskModel,
    settings: AppSettingsModel,
    filesDir: string,
    onUpdate: () => void
  ): Promise<void> {
    task.status = TaskStatus.RUNNING;
    onUpdate();

    const safeTitle = this.sanitizeFilename(task.title);
    const outPath = `${filesDir}/${safeTitle}_${Date.now()}.${task.ext}`;
    const file = fileIo.openSync(outPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    const req = http.createHttp();

    const ctrl: LiveSessionControl = { stopMode: 'none', activeReq: req, splitWaiter: null };
    this.sessions.set(task.id, ctrl);

    let received = 0;
    let total = 0;
    const startedMs = Date.now();

    req.on('dataReceive', (chunk: ArrayBuffer) => {
      if (ctrl.stopMode === 'cancel') {
        return;
      }
      fileIo.writeSync(file.fd, chunk);
      received += chunk.byteLength;
    });

    req.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
      received = info.receiveSize;
      total = info.totalSize;
      if (total > 0) {
        task.progress = Math.min(1, received / total);
        task.totalSizeText = formatBytes(total);
      }
      const elapsedSec = Math.max(0.2, (Date.now() - startedMs) / 1000);
      task.speedText = `${formatBytes(received / elapsedSec)}/s`;
      onUpdate();
    });

    try {
      const headers: Record<string, string> = {
        'User-Agent': task.userAgent || DEFAULT_UA
      };
      if (task.referer.length > 0) {
        headers['Referer'] = task.referer;
      }
      if (settings.biliSessData.trim().length > 0) {
        headers['Cookie'] = `SESSDATA=${settings.biliSessData.trim()}`;
      }

      const code = await req.requestInStream(task.streamUrl, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 600000
      });
      if (ctrl.stopMode === 'cancel') {
        fileIo.closeSync(file.fd);
        try {
          fileIo.unlinkSync(outPath);
        } catch (_err) {}
        task.status = TaskStatus.CANCELED;
        onUpdate();
        return;
      }
      if (code >= 400) {
        throw new Error(`HTTP ${code}`);
      }
      fileIo.closeSync(file.fd);
      task.outputFile = outPath;
      task.savedFiles = [outPath];
      task.progress = 1;
      task.status = TaskStatus.DONE;
      onUpdate();
    } catch (err) {
      try {
        fileIo.closeSync(file.fd);
      } catch (_e) {}
      if (ctrl.stopMode === 'cancel') {
        task.status = TaskStatus.CANCELED;
      } else {
        task.status = TaskStatus.ERROR;
        task.errorMessage = `${err}`;
      }
      onUpdate();
    } finally {
      req.destroy();
      this.sessions.delete(task.id);
    }
  }

  /**
   * 实时录制 HLS（fMP4 / TS）直播流，并在任意时间戳支持停止保存与分段断点保存为完整可播放文件。
   */
  private async recordHlsLive(
    task: DownloadTaskModel,
    settings: AppSettingsModel,
    filesDir: string,
    onUpdate: () => void
  ): Promise<void> {
    task.status = TaskStatus.RECORDING;
    onUpdate();

    const ctrl: LiveSessionControl = { stopMode: 'none', activeReq: null, splitWaiter: null };
    this.sessions.set(task.id, ctrl);

    const safeTitle = this.sanitizeFilename(task.title);
    const stamp = this.formatStamp();
    const startMs = Date.now();
    let segIndex = 1;
    let totalBytes = 0;
    const seenSegments = new Set<string>();
    let initData: ArrayBuffer | null = null;
    let lastInitUrl = '';

    const headers: Record<string, string> = {
      'User-Agent': task.userAgent || DEFAULT_UA
    };
    if (task.referer.length > 0) {
      headers['Referer'] = task.referer;
    }
    if (settings.biliSessData.trim().length > 0) {
      headers['Cookie'] = `SESSDATA=${settings.biliSessData.trim()}`;
    }

    try {
      while (ctrl.stopMode !== 'stop' && ctrl.stopMode !== 'cancel') {
        const suffix = segIndex === 1 ? '' : `_part${segIndex.toString().padStart(2, '0')}`;
        const segPath = `${filesDir}/${safeTitle}_live_${stamp}${suffix}.${task.ext}`;
        const file = fileIo.openSync(segPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        let segBytes = 0;

        if (initData !== null) {
          fileIo.writeSync(file.fd, initData);
          segBytes += initData.byteLength;
        }

        try {
          while (ctrl.stopMode === 'none') {
            if (task.maxDurationSeconds > 0 && (Date.now() - startMs) / 1000 >= task.maxDurationSeconds) {
              ctrl.stopMode = 'stop';
              break;
            }

            const playlistText = await this.getText(task.streamUrl, headers);
            const lines = playlistText.split(/\r?\n/);
            let mapUri = '';
            const segUrls: string[] = [];

            for (let i = 0; i < lines.length; i++) {
              const line = lines[i].trim();
              if (line.startsWith('#EXT-X-MAP:')) {
                const uriMatch = line.match(/URI="([^"]+)"/);
                if (uriMatch && uriMatch.length >= 2) {
                  mapUri = this.resolveRelativeUrl(task.streamUrl, uriMatch[1]);
                }
              } else if (line.length > 0 && !line.startsWith('#')) {
                segUrls.push(this.resolveRelativeUrl(task.streamUrl, line));
              }
            }

            if (mapUri.length > 0 && mapUri !== lastInitUrl) {
              initData = await this.getBinary(mapUri, headers);
              lastInitUrl = mapUri;
              fileIo.writeSync(file.fd, initData);
              segBytes += initData.byteLength;
              totalBytes += initData.byteLength;
            }

            let downloadedAny = false;
            for (let i = 0; i < segUrls.length; i++) {
              if (ctrl.stopMode !== 'none') {
                break;
              }
              const sUrl = segUrls[i];
              if (seenSegments.has(sUrl)) {
                continue;
              }
              seenSegments.add(sUrl);
              if (seenSegments.size > 400) {
                const firstKey = seenSegments.values().next().value as string | undefined;
                if (firstKey) {
                  seenSegments.delete(firstKey);
                }
              }

              const buf = await this.getBinary(sUrl, headers);
              fileIo.writeSync(file.fd, buf);
              segBytes += buf.byteLength;
              totalBytes += buf.byteLength;
              downloadedAny = true;

              const elapsedSec = Math.max(1, Math.floor((Date.now() - startMs) / 1000));
              task.recordedDuration = formatDuration(elapsedSec);
              task.recordedSize = formatBytes(totalBytes);
              task.bitrateText = `${((totalBytes * 8) / elapsedSec / 1000000).toFixed(2)} Mbps`;
              task.segmentIndex = segIndex;
              onUpdate();
            }

            if (ctrl.stopMode !== 'none') {
              break;
            }
            await this.sleep(downloadedAny ? 600 : 1200);
          }
        } finally {
          fileIo.closeSync(file.fd);
        }

        if (ctrl.stopMode === 'cancel' && segBytes <= 1024) {
          try {
            fileIo.unlinkSync(segPath);
          } catch (_e) {}
          task.status = TaskStatus.CANCELED;
          onUpdate();
          return;
        }

        if (segBytes > 0) {
          task.savedFiles = [...task.savedFiles, segPath];
          task.outputFile = segPath;
        }

        if (ctrl.stopMode === 'split') {
          ctrl.stopMode = 'none';
          const waiter = ctrl.splitWaiter;
          ctrl.splitWaiter = null;
          if (waiter) {
            waiter(segBytes > 0 ? segPath : null);
          }
          segIndex++;
          task.segmentIndex = segIndex;
          onUpdate();
          continue;
        }

        break;
      }

      task.status = TaskStatus.DONE;
      task.progress = 1;
      onUpdate();
    } catch (err) {
      task.status = TaskStatus.ERROR;
      task.errorMessage = `${err}`;
      onUpdate();
    } finally {
      this.sessions.delete(task.id);
    }
  }

  /**
   * 实时录制 HTTP-FLV 直播流，自动捕获 FLV Header 与音视频 Sequence Header，
   * 支持任意时刻停止保存或断点分段保存（每个分段均自带完整 FLV 头与解码序列头，独立可播）。
   */
  private async recordFlvLive(
    task: DownloadTaskModel,
    settings: AppSettingsModel,
    filesDir: string,
    onUpdate: () => void
  ): Promise<void> {
    task.status = TaskStatus.RECORDING;
    onUpdate();

    const ctrl: LiveSessionControl = { stopMode: 'none', activeReq: null, splitWaiter: null };
    this.sessions.set(task.id, ctrl);

    const safeTitle = this.sanitizeFilename(task.title);
    const stamp = this.formatStamp();
    const startMs = Date.now();
    let segIndex = 1;
    let totalBytes = 0;

    // 捕获前 ~4KB 的 FLV 头与 Script/AVC/AAC Sequence Header 用于断点切分时注入新文件头部
    const flvHeaderCapture: FlvHeaderCapture = {
      bytes: new Uint8Array(0),
      done: false
    };

    const headers: Record<string, string> = {
      'User-Agent': task.userAgent || DEFAULT_UA
    };
    if (task.referer.length > 0) {
      headers['Referer'] = task.referer;
    }
    if (settings.biliSessData.trim().length > 0) {
      headers['Cookie'] = `SESSDATA=${settings.biliSessData.trim()}`;
    }

    try {
      while (ctrl.stopMode !== 'stop' && ctrl.stopMode !== 'cancel') {
        const suffix = segIndex === 1 ? '' : `_part${segIndex.toString().padStart(2, '0')}`;
        const segPath = `${filesDir}/${safeTitle}_live_${stamp}${suffix}.${task.ext}`;
        let file = fileIo.openSync(segPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        let segBytes = 0;
        let currentSegPath = segPath;

        if (segIndex > 1 && flvHeaderCapture.done && flvHeaderCapture.bytes.byteLength > 0) {
          fileIo.writeSync(file.fd, flvHeaderCapture.bytes.buffer);
          segBytes += flvHeaderCapture.bytes.byteLength;
        }

        const req = http.createHttp();
        ctrl.activeReq = req;

        const timerId = setInterval(() => {
          const elapsedSec = Math.max(1, Math.floor((Date.now() - startMs) / 1000));
          task.recordedDuration = formatDuration(elapsedSec);
          task.recordedSize = formatBytes(totalBytes);
          task.bitrateText = `${((totalBytes * 8) / elapsedSec / 1000000).toFixed(2)} Mbps`;
          onUpdate();
          if (task.maxDurationSeconds > 0 && elapsedSec >= task.maxDurationSeconds) {
            ctrl.stopMode = 'stop';
            req.destroy();
          }
        }, 800);

        req.on('dataReceive', (chunk: ArrayBuffer) => {
          if (ctrl.stopMode === 'cancel') {
            return;
          }
          if (!flvHeaderCapture.done) {
            const incoming = new Uint8Array(chunk);
            const combined = new Uint8Array(flvHeaderCapture.bytes.length + incoming.length);
            combined.set(flvHeaderCapture.bytes, 0);
            combined.set(incoming, flvHeaderCapture.bytes.length);
            if (combined.length >= 13) {
              const extracted = this.extractFlvBootstrapHeader(combined);
              if (extracted !== null) {
                flvHeaderCapture.bytes = extracted;
                flvHeaderCapture.done = true;
              } else if (combined.length > 8192) {
                flvHeaderCapture.bytes = combined.slice(0, 13);
                flvHeaderCapture.done = true;
              } else {
                flvHeaderCapture.bytes = combined;
              }
            } else {
              flvHeaderCapture.bytes = combined;
            }
          }
          fileIo.writeSync(file.fd, chunk);
          segBytes += chunk.byteLength;
          totalBytes += chunk.byteLength;
        });

        try {
          await req.requestInStream(task.streamUrl, {
            method: http.RequestMethod.GET,
            header: headers,
            connectTimeout: 15000,
            readTimeout: 86400000
          });
        } catch (_streamErr) {
          // 停止或切分主动 destroy 会抛出中断错误，属正常预期
        } finally {
          clearInterval(timerId);
          req.destroy();
          fileIo.closeSync(file.fd);
        }

        if (ctrl.stopMode === 'cancel' && segBytes <= 1024) {
          try {
            fileIo.unlinkSync(currentSegPath);
          } catch (_e) {}
          task.status = TaskStatus.CANCELED;
          onUpdate();
          return;
        }

        if (segBytes > 1024) {
          task.savedFiles = [...task.savedFiles, currentSegPath];
          task.outputFile = currentSegPath;
        }

        if (ctrl.stopMode === 'split') {
          ctrl.stopMode = 'none';
          const waiter = ctrl.splitWaiter;
          ctrl.splitWaiter = null;
          if (waiter) {
            waiter(segBytes > 1024 ? currentSegPath : null);
          }
          segIndex++;
          task.segmentIndex = segIndex;
          onUpdate();
          continue;
        }

        break;
      }

      task.status = TaskStatus.DONE;
      task.progress = 1;
      onUpdate();
    } catch (err) {
      task.status = TaskStatus.ERROR;
      task.errorMessage = `${err}`;
      onUpdate();
    } finally {
      this.sessions.delete(task.id);
    }
  }

  /**
   * 从 FLV 流开头解析完整的 FLV Header + Script/Video/Audio Sequence Header 标签边界。
   */
  private extractFlvBootstrapHeader(buf: Uint8Array): Uint8Array | null {
    if (buf.length < 13 || buf[0] !== 0x46 || buf[1] !== 0x4c || buf[2] !== 0x56) {
      return null;
    }
    let offset = 13;
    let sawVideoSeq = false;
    let sawAudioSeq = false;

    while (offset + 11 <= buf.length) {
      const tagType = buf[offset] & 0x1f;
      const dataSize = (buf[offset + 1] << 16) | (buf[offset + 2] << 8) | buf[offset + 3];
      const nextOffset = offset + 11 + dataSize + 4;
      if (nextOffset > buf.length) {
        return null;
      }
      if (tagType === 9 && dataSize >= 2) {
        const avcPacketType = buf[offset + 12];
        if (avcPacketType === 0) {
          sawVideoSeq = true;
          offset = nextOffset;
          if (sawVideoSeq && sawAudioSeq) {
            return buf.slice(0, offset);
          }
          continue;
        }
        return offset > 13 ? buf.slice(0, offset) : null;
      } else if (tagType === 8 && dataSize >= 2) {
        const aacPacketType = buf[offset + 12];
        if (aacPacketType === 0) {
          sawAudioSeq = true;
          offset = nextOffset;
          if (sawVideoSeq && sawAudioSeq) {
            return buf.slice(0, offset);
          }
          continue;
        }
        return offset > 13 ? buf.slice(0, offset) : null;
      } else if (tagType === 18) {
        offset = nextOffset;
        continue;
      }
      break;
    }
    return null;
  }

  private async runViaBridge(
    task: DownloadTaskModel,
    bridgeUrl: string,
    filesDir: string,
    onUpdate: () => void
  ): Promise<void> {
    task.status = task.isLive ? TaskStatus.RECORDING : TaskStatus.RUNNING;
    onUpdate();

    const ctrl: LiveSessionControl = { stopMode: 'none', activeReq: null, splitWaiter: null };
    this.sessions.set(task.id, ctrl);

    try {
      const startResp = await this.postJson<BridgeStartJson>(
        `${bridgeUrl}/api/task/start`,
        JSON.stringify({
          url: task.url,
          title: task.title,
          format_selector: task.formatSelector,
          audio_only: task.audioOnly,
          is_live: task.isLive,
          live_from_start: task.liveFromStart,
          max_duration_seconds: task.maxDurationSeconds
        })
      );
      if (startResp.error || !startResp.task_id) {
        throw new Error(startResp.error ?? '协同服务启动任务失败');
      }
      task.bridgeTaskId = startResp.task_id;

      while (true) {
        await this.sleep(800);
        const st = await this.getJson<BridgeStatusJson>(
          `${bridgeUrl}/api/task/status?task_id=${encodeURIComponent(task.bridgeTaskId)}`,
          {}
        );
        task.progress = st.progress ?? task.progress;
        task.recordedDuration = st.recorded_duration ?? task.recordedDuration;
        task.recordedSize = st.recorded_size ?? task.recordedSize;
        task.bitrateText = st.bitrate ?? task.bitrateText;
        task.speedText = st.speed ?? task.speedText;
        task.totalSizeText = st.total_size ?? task.totalSizeText;
        task.segmentIndex = st.segment_index ?? task.segmentIndex;
        if (st.saved_files && st.saved_files.length > 0) {
          task.savedFiles = st.saved_files;
        }
        if (st.output_file) {
          task.outputFile = st.output_file;
        }

        if (st.status === 'finalizing') {
          task.status = TaskStatus.FINALIZING;
          onUpdate();
        } else if (st.status === 'done') {
          // 若服务端已完成，将最新的完整可播放文件拉取到鸿蒙本机目录
          if (task.outputFile && task.outputFile.length > 0) {
            const localPath = await this.pullBridgeFile(bridgeUrl, task.outputFile, filesDir);
            if (localPath) {
              task.outputFile = localPath;
              task.savedFiles = [...task.savedFiles.filter((p) => p !== localPath), localPath];
            }
          }
          task.status = TaskStatus.DONE;
          task.progress = 1;
          onUpdate();
          break;
        } else if (st.status === 'error') {
          throw new Error(st.error ?? '协同录制失败');
        } else if (st.status === 'canceled') {
          task.status = TaskStatus.CANCELED;
          onUpdate();
          break;
        } else {
          onUpdate();
        }
      }
    } catch (err) {
      task.status = TaskStatus.ERROR;
      task.errorMessage = `${err}`;
      onUpdate();
    } finally {
      this.sessions.delete(task.id);
    }
  }

  private async pullBridgeFile(bridgeUrl: string, remotePath: string, filesDir: string): Promise<string | null> {
    const parts = remotePath.split(/[\\/]/);
    const filename = parts[parts.length - 1] || `vdown_${Date.now()}.mp4`;
    const localPath = `${filesDir}/${filename}`;
    try {
      const bin = await this.getBinary(`${bridgeUrl}/api/file?path=${encodeURIComponent(remotePath)}`, {});
      const file = fileIo.openSync(localPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bin);
      fileIo.closeSync(file.fd);
      return localPath;
    } catch (_err) {
      return null;
    }
  }

  async stopAndSave(task: DownloadTaskModel, settings: AppSettingsModel, onUpdate: () => void): Promise<void> {
    if (task.viaBridge && settings.bridgeUrl.trim().length > 0 && task.bridgeTaskId.length > 0) {
      const bridge = settings.bridgeUrl.trim().replace(/\/+$/, '');
      task.status = TaskStatus.FINALIZING;
      onUpdate();
      await this.postJson<BridgeStatusJson>(
        `${bridge}/api/task/stop`,
        JSON.stringify({ task_id: task.bridgeTaskId })
      );
      return;
    }
    const ctrl = this.sessions.get(task.id);
    if (!ctrl) {
      return;
    }
    task.status = TaskStatus.FINALIZING;
    onUpdate();
    ctrl.stopMode = 'stop';
    if (ctrl.activeReq) {
      ctrl.activeReq.destroy();
    }
  }

  async splitCheckpoint(task: DownloadTaskModel, settings: AppSettingsModel, filesDir: string): Promise<string | null> {
    if (task.viaBridge && settings.bridgeUrl.trim().length > 0 && task.bridgeTaskId.length > 0) {
      const bridge = settings.bridgeUrl.trim().replace(/\/+$/, '');
      const resp = await this.postJson<BridgeSplitJson>(
        `${bridge}/api/task/split`,
        JSON.stringify({ task_id: task.bridgeTaskId })
      );
      if (resp.saved_file) {
        const local = await this.pullBridgeFile(bridge, resp.saved_file, filesDir);
        return local ?? resp.saved_file;
      }
      return null;
    }
    const ctrl = this.sessions.get(task.id);
    if (!ctrl) {
      return null;
    }
    return await new Promise<string | null>((resolve) => {
      ctrl.splitWaiter = resolve;
      ctrl.stopMode = 'split';
      if (ctrl.activeReq) {
        ctrl.activeReq.destroy();
      }
      setTimeout(() => {
        if (ctrl.splitWaiter === resolve) {
          ctrl.splitWaiter = null;
          resolve(null);
        }
      }, 15000);
    });
  }

  async cancelTask(task: DownloadTaskModel, settings: AppSettingsModel): Promise<void> {
    if (task.viaBridge && settings.bridgeUrl.trim().length > 0 && task.bridgeTaskId.length > 0) {
      const bridge = settings.bridgeUrl.trim().replace(/\/+$/, '');
      await this.postJson<BridgeStatusJson>(
        `${bridge}/api/task/cancel`,
        JSON.stringify({ task_id: task.bridgeTaskId })
      );
      return;
    }
    const ctrl = this.sessions.get(task.id);
    if (ctrl) {
      ctrl.stopMode = 'cancel';
      ctrl.activeReq?.destroy();
    }
  }

  /**
   * 通过鸿蒙系统 DocumentViewPicker 将录制好的可播放视频导出到用户“文件管理 / 下载”目录。
   */
  async exportToUserFiles(localPath: string, uiContext: Context): Promise<string | null> {
    const parts = localPath.split('/');
    const fileName = parts[parts.length - 1] || `VDown_${Date.now()}.mp4`;
    const saveOpts = new picker.DocumentSaveOptions();
    saveOpts.newFileNames = [fileName];
    const docPicker = new picker.DocumentViewPicker(uiContext);
    const uris = await docPicker.save(saveOpts);
    if (!uris || uris.length === 0) {
      return null;
    }
    const destUri = uris[0];
    const src = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
    const dst = fileIo.openSync(destUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      const buf = new ArrayBuffer(262144);
      let readLen = fileIo.readSync(src.fd, buf);
      while (readLen > 0) {
        fileIo.writeSync(dst.fd, buf.slice(0, readLen));
        readLen = fileIo.readSync(src.fd, buf);
      }
    } finally {
      fileIo.closeSync(src.fd);
      fileIo.closeSync(dst.fd);
    }
    return destUri;
  }

  private async getJson<T>(url: string, headers: Record<string, string>): Promise<T> {
    const text = await this.getText(url, headers);
    return JSON.parse(text) as T;
  }

  private async postJson<T>(url: string, body: string): Promise<T> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'User-Agent': DEFAULT_UA
        },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 45000
      });
      const text = typeof resp.result === 'string' ? resp.result : `${resp.result}`;
      return JSON.parse(text) as T;
    } finally {
      req.destroy();
    }
  }

  private async getText(url: string, headers: Record<string, string>): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000
      });
      if (resp.responseCode >= 400) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      if (typeof resp.result === 'string') {
        return resp.result;
      }
      if (resp.result instanceof ArrayBuffer) {
        const dec = new util.TextDecoder('utf-8');
        return dec.decodeToString(new Uint8Array(resp.result));
      }
      return `${resp.result}`;
    } finally {
      req.destroy();
    }
  }

  private async getBinary(url: string, headers: Record<string, string>): Promise<ArrayBuffer> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (resp.responseCode >= 400) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      return resp.result as ArrayBuffer;
    } finally {
      req.destroy();
    }
  }

  private resolveRelativeUrl(baseUrl: string, ref: string): string {
    if (ref.startsWith('http://') || ref.startsWith('https://')) {
      return ref;
    }
    const qIdx = baseUrl.indexOf('?');
    const cleanBase = qIdx >= 0 ? baseUrl.substring(0, qIdx) : baseUrl;
    if (ref.startsWith('/')) {
      const protoEnd = cleanBase.indexOf('://');
      const slashIdx = cleanBase.indexOf('/', protoEnd + 3);
      const origin = slashIdx >= 0 ? cleanBase.substring(0, slashIdx) : cleanBase;
      return `${origin}${ref}`;
    }
    const lastSlash = cleanBase.lastIndexOf('/');
    const dir = lastSlash >= 0 ? cleanBase.substring(0, lastSlash + 1) : `${cleanBase}/`;
    return `${dir}${ref}`;
  }

  private sanitizeFilename(raw: string): string {
    const cleaned = raw.replace(/[\\/:*?"<>|\r\n]+/g, '_').replace(/\s+/g, ' ').trim();
    if (cleaned.length === 0) {
      return 'vdown_media';
    }
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  private formatStamp(): string {
    const d = new Date();
    const y = d.getFullYear().toString();
    const m = (d.getMonth() + 1).toString().padStart(2, '0');
    const day = d.getDate().toString().padStart(2, '0');
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    const ss = d.getSeconds().toString().padStart(2, '0');
    return `${y}${m}${day}_${hh}${mm}${ss}`;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
