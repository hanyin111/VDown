export enum TaskStatus {
  QUEUED = 0,
  RUNNING = 1,
  RECORDING = 2,
  FINALIZING = 3,
  DONE = 4,
  ERROR = 5,
  CANCELED = 6
}

export class VideoFormatModel {
  formatId: string = '';
  ext: string = 'mp4';
  height: number = 0;
  fps: number = 0;
  vcodec: string = '';
  acodec: string = '';
  filesize: number = 0;
  tbr: number = 0;
  formatNote: string = '';
  quality: number = 0;
  streamUrl: string = '';
  referer: string = '';
  userAgent: string = '';
  isHls: boolean = false;

  get displayLabel(): string {
    if (this.height > 0) {
      return this.fps > 40 ? `${this.height}P ${Math.round(this.fps)}fps` : `${this.height}P`;
    }
    if (this.formatNote.length > 0) {
      return this.formatNote;
    }
    return this.formatId;
  }
}

export class VideoInfoModel {
  id: string = '';
  title: string = '';
  uploader: string = '';
  thumbnail: string = '';
  durationSeconds: number = 0;
  webpageUrl: string = '';
  extractor: string = '';
  isLive: boolean = false;
  isYouTube: boolean = false;
  viaBridge: boolean = false;
  formats: VideoFormatModel[] = [];
}

@Observed
export class DownloadTaskModel {
  id: string = '';
  url: string = '';
  title: string = '';
  thumbnail: string = '';
  qualityLabel: string = '';
  formatId: string = '';
  formatSelector: string = '';
  streamUrl: string = '';
  referer: string = '';
  userAgent: string = '';
  ext: string = 'mp4';
  isLive: boolean = false;
  isHls: boolean = false;
  audioOnly: boolean = false;
  liveFromStart: boolean = false;
  maxDurationSeconds: number = 0;
  viaBridge: boolean = false;
  bridgeTaskId: string = '';

  status: TaskStatus = TaskStatus.QUEUED;
  progress: number = 0;
  totalSizeText: string = '';
  speedText: string = '';
  recordedDuration: string = '00:00:00';
  recordedSize: string = '0 B';
  bitrateText: string = '';
  segmentIndex: number = 1;
  savedFiles: string[] = [];
  outputFile: string = '';
  errorMessage: string = '';

  isActive(): boolean {
    return this.status === TaskStatus.QUEUED ||
      this.status === TaskStatus.RUNNING ||
      this.status === TaskStatus.RECORDING ||
      this.status === TaskStatus.FINALIZING;
  }
}

export interface AppSettingsModel {
  bridgeUrl: string;
  proxyUrl: string;
  biliSessData: string;
  preferFmp4Live: boolean;
  glassEnabled: boolean;
  darkBackdrop: boolean;
}

export function formatDuration(seconds: number): string {
  if (seconds <= 0) {
    return '--:--';
  }
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  const mm = m.toString().padStart(2, '0');
  const ss = s.toString().padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

export function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB'];
  let val = bytes;
  let idx = 0;
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx++;
  }
  return `${val >= 100 ? val.toFixed(0) : val.toFixed(1)} ${units[idx]}`;
}

export function extractUrl(text: string): string | null {
  const match = text.match(/https?:\/\/[^\s\u3000-\u9fff\uff00-\uffef]+/);
  return match ? match[0] : null;
}
