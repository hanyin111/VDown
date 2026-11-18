import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import {
  hdsMaterial,
  HdsSnackBar,
  HdsTabs,
  HdsTabsController,
  SnackBarIconOptions,
  SnackBarIconType,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarOperationType
} from '@kit.UIDesignKit';
import { GlassPalette } from '../components/GlassStyles';
import {
  AppSettingsModel,
  DownloadTaskModel,
  extractUrl,
  formatBytes,
  formatDuration,
  TaskStatus,
  VideoFormatModel,
  VideoInfoModel
} from '../models/VDownModels';
import { SettingsStore } from '../services/SettingsStore';
import { VDownEngine } from '../services/VDownEngine';

class DurationOption {
  seconds: number;
  label: string;

  constructor(seconds: number, label: string) {
    this.seconds = seconds;
    this.label = label;
  }
}

const LIVE_DURATION_OPTIONS: DurationOption[] = [
  new DurationOption(0, '手动停止（任意时刻断点保存）'),
  new DurationOption(1800, '30 分钟'),
  new DurationOption(3600, '1 小时'),
  new DurationOption(7200, '2 小时')
];

@Entry
@Component
struct Index {
  @StorageLink('topAvoidVp') topAvoidVp: number = 38;
  @StorageLink('bottomAvoidVp') bottomAvoidVp: number = 28;
  @StorageLink('vdownFilesDir') filesDir: string = '';

  @State currentTab: number = 0;
  @State urlInput: string = '';
  @State parsing: boolean = false;
  @State parseError: string = '';
  @State parsedInfo: VideoInfoModel | null = null;
  @State selectedFormatIdx: number = 0;
  @State audioOnly: boolean = false;
  @State liveFromStart: boolean = false;
  @State liveMaxDurationSec: number = 0;

  @State tasks: DownloadTaskModel[] = [];
  @State taskTick: number = 0;

  @State settings: AppSettingsModel = {
    bridgeUrl: '',
    proxyUrl: '',
    biliSessData: '',
    preferFmp4Live: true,
    glassEnabled: true,
    darkBackdrop: true
  };

  private tabsController: HdsTabsController = new HdsTabsController();
  private engine: VDownEngine = new VDownEngine();
  private snackBar: HdsSnackBar | null = null;

  aboutToAppear(): void {
    SettingsStore.load(getContext(this)).then((loaded) => {
      this.settings = loaded;
    });
    try {
      this.snackBar = new HdsSnackBar(this.getUIContext());
    } catch (_err) {
      this.snackBar = null;
    }
  }

  private showToast(msg: string, actionLabel?: string, onAction?: () => void): void {
    try {
      if (this.snackBar !== null) {
        const iconOpt: SnackBarIconOptions = {
          iconType: SnackBarIconType.SMALL,
          icon: $r('sys.symbol.checkmark_circle_fill')
        };
        const msgOpt: SnackBarMessageOptions = {
          title: msg
        };
        const opOpt: SnackBarOperationOptions = {
          operationType: actionLabel ? SnackBarOperationType.TEXT_ONLY : SnackBarOperationType.CLOSE_BUTTON_ONLY,
          content: actionLabel ?? '',
          onContentClick: () => {
            if (onAction) {
              onAction();
            }
            this.snackBar?.dismiss();
          },
          onCloseButtonClick: () => {
            this.snackBar?.dismiss();
          }
        };
        this.snackBar.show(iconOpt, msgOpt, opOpt);
        return;
      }
    } catch (_err) {
      // fallback to promptAction
    }
    promptAction.showToast({ message: msg, duration: 2400 });
  }

  private async pasteLink(): Promise<void> {
    try {
      const sysBoard = pasteboard.getSystemPasteboard();
      const data = await sysBoard.getData();
      const text = data.getPrimaryText();
      if (text && text.trim().length > 0) {
        this.urlInput = extractUrl(text.trim()) ?? text.trim();
      }
    } catch (_err) {
      this.showToast('未能读取剪贴板，请直接粘贴链接');
    }
  }

  private async handleParse(): Promise<void> {
    const raw = this.urlInput.trim();
    if (raw.length === 0 || this.parsing) {
      return;
    }
    const extracted = extractUrl(raw) ?? raw;
    this.urlInput = extracted;
    this.parsing = true;
    this.parseError = '';
    this.parsedInfo = null;
    this.selectedFormatIdx = 0;
    this.audioOnly = false;
    this.liveFromStart = false;
    this.liveMaxDurationSec = 0;

    try {
      const info = await this.engine.parseVideo(extracted, this.settings);
      this.parsedInfo = info;
      if (info.formats.length === 0) {
        this.audioOnly = true;
      }
    } catch (err) {
      this.parseError = err instanceof Error ? err.message : `${err}`;
    } finally {
      this.parsing = false;
    }
  }

  private startDownloadOrRecord(): void {
    const info = this.parsedInfo;
    if (!info) {
      return;
    }
    const fmt: VideoFormatModel | null =
      (!this.audioOnly && info.formats.length > this.selectedFormatIdx)
        ? info.formats[this.selectedFormatIdx]
        : null;

    const task = new DownloadTaskModel();
    task.id = `${Date.now()}_${Math.floor(Math.random() * 1000)}`;
    task.url = info.webpageUrl.length > 0 ? info.webpageUrl : this.urlInput.trim();
    task.title = info.title;
    task.thumbnail = info.thumbnail;
    task.isLive = info.isLive;
    task.viaBridge = info.viaBridge;
    task.audioOnly = this.audioOnly || fmt === null;
    task.liveFromStart = info.isLive && info.isYouTube && this.liveFromStart;
    task.maxDurationSeconds = info.isLive ? this.liveMaxDurationSec : 0;

    if (task.audioOnly) {
      task.formatId = 'bestaudio';
      task.formatSelector = 'bestaudio/best';
      task.ext = 'mp3';
      task.qualityLabel = info.isLive ? '直播音频 · MP3' : '音频 · MP3';
    } else if (fmt !== null) {
      task.formatId = fmt.formatId;
      const needsBestAudio = (fmt.acodec.length === 0 || fmt.acodec === 'none') && info.isYouTube;
      task.formatSelector = needsBestAudio ? `${fmt.formatId}+bestaudio/${fmt.formatId}/best` : `${fmt.formatId}/best`;
      task.streamUrl = fmt.streamUrl;
      task.referer = fmt.referer;
      task.userAgent = fmt.userAgent;
      task.ext = fmt.ext;
      task.isHls = fmt.isHls;
      task.qualityLabel = info.isLive
        ? `直播 ${fmt.displayLabel} · ${fmt.ext.toUpperCase()}`
        : `${fmt.displayLabel} · ${fmt.ext.toUpperCase()}`;
    }

    this.tasks = [task, ...this.tasks];
    this.taskTick++;

    const dir = this.filesDir.length > 0 ? this.filesDir : getContext(this).filesDir;
    this.engine.runTask(task, this.settings, dir, () => {
      this.taskTick++;
    });

    this.showToast(
      info.isLive ? `已开始实时录制：${info.title}` : `已加入下载队列：${info.title}`,
      '查看任务',
      () => {
        this.currentTab = 1;
        this.tabsController.changeIndex(1);
      }
    );
  }

  private primaryText(): string {
    return this.settings.darkBackdrop ? '#F3F6FC' : '#111827';
  }

  private secondaryText(): string {
    return this.settings.darkBackdrop ? '#A8B7D4' : '#4B5563';
  }

  private accentColor(): string {
    return this.settings.darkBackdrop ? '#60A5FA' : '#1A73E8';
  }

  private cardFallbackBg(): string {
    return this.settings.darkBackdrop ? '#1E293B88' : '#FFFFFFAA';
  }

  private cardBorderColor(): string {
    return this.settings.darkBackdrop ? '#FFFFFF28' : '#FFFFFFCC';
  }

  @Builder
  AmbientBackdrop() {
    Stack() {
      // 底层渐变基底，保证高动态光影透射效果
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 145,
          colors: this.settings.darkBackdrop
            ? [['#070D1D', 0.0], ['#0F1F45', 0.45], ['#0A162F', 1.0]]
            : [['#E8F1FF', 0.0], ['#DCEBFF', 0.48], ['#F2F7FF', 1.0]]
        })

      // 顶部极光蓝光斑（为玻璃卡片提供通透折射与层叠感）
      Circle({ width: 320, height: 320 })
        .fill(this.settings.darkBackdrop ? '#2563EB48' : '#60A5FA40')
        .blur(72)
        .position({ x: -80, y: -60 })

      // 中右青碧光晕
      Circle({ width: 280, height: 280 })
        .fill(this.settings.darkBackdrop ? '#06B6D438' : '#38BDF838')
        .blur(80)
        .position({ x: '52%', y: '24%' })

      // 底部紫蓝光斑（增强 HdsTabs 悬浮玻璃胶囊的反光质感）
      Circle({ width: 300, height: 300 })
        .fill(this.settings.darkBackdrop ? '#6366F138' : '#818CF830')
        .blur(86)
        .position({ x: '15%', y: '72%' })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  GlassHeader(title: string, subtitle: string) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(title)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
        if (this.settings.glassEnabled) {
          Text('HarmonyOS 7 Glass')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentColor())
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(12)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
            .systemMaterial(GlassPalette.pillMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
            .border({ width: 0.5, color: this.cardBorderColor() })
        }
      }
      Text(subtitle)
        .fontSize(13)
        .fontColor(this.secondaryText())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: this.topAvoidVp + 12, bottom: 12 })
  }

  @Builder
  DownloadTabView() {
    Scroll() {
      Column({ space: 16 }) {
        this.GlassHeader('VDown', '支持 Bilibili / YouTube 直播实时录制与任意时间戳断点保存')

        // 链接输入玻璃卡片
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            TextInput({ text: this.urlInput, placeholder: '粘贴 B站 / YouTube 直播或视频链接…' })
              .layoutWeight(1)
              .height(48)
              .fontSize(15)
              .fontColor(this.primaryText())
              .placeholderColor(this.secondaryText())
              .backgroundColor(this.settings.darkBackdrop ? '#0F172A55' : '#FFFFFF88')
              .borderRadius(16)
              .onChange((val: string) => {
                this.urlInput = val;
              })
              .onSubmit(() => {
                this.handleParse();
              })

            Button() {
              SymbolGlyph($r('sys.symbol.clipboard_sharing'))
                .fontSize(20)
                .fontColor([this.primaryText()])
            }
            .width(48)
            .height(48)
            .borderRadius(16)
            .backgroundColor(this.cardFallbackBg())
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
            .systemMaterial(GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
            .onClick(() => {
              this.pasteLink();
            })
          }

          Button() {
            Row({ space: 8 }) {
              if (this.parsing) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color('#FFFFFF')
              } else {
                SymbolGlyph($r('sys.symbol.magnifyingglass'))
                  .fontSize(18)
                  .fontColor(['#FFFFFF'])
              }
              Text(this.parsing ? '正在解析流媒体信息…' : '解析视频 / 直播流')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
            }
          }
          .width('100%')
          .height(48)
          .borderRadius(16)
          .backgroundColor('#1A73E8CC')
          .systemMaterial(GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop, '#1A73E8B8'))
          .enabled(!this.parsing)
          .onClick(() => {
            this.handleParse();
          })
        }
        .padding(16)
        .borderRadius(24)
        .backgroundColor(this.cardFallbackBg())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
        .border({ width: 0.8, color: this.cardBorderColor() })

        // 错误提示玻璃卡片
        if (this.parseError.length > 0) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
              .fontSize(20)
              .fontColor(['#F87171'])
            Text(this.parseError)
              .fontSize(13)
              .fontColor(this.settings.darkBackdrop ? '#FECACA' : '#991B1B')
              .layoutWeight(1)
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor(this.settings.darkBackdrop ? '#7F1D1D66' : '#FEE2E2BB')
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
          .border({ width: 0.8, color: '#F8717166' })
        }

        // 解析结果玻璃卡片
        if (this.parsedInfo !== null) {
          this.ParsedInfoSection(this.parsedInfo!)
        }

        // 底部留白避免被悬浮 TabBar 遮挡
        Blank().height(100 + this.bottomAvoidVp)
      }
      .padding({ left: 16, right: 16 })
      .width('100%')
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  @Builder
  ParsedInfoSection(info: VideoInfoModel) {
    Column({ space: 14 }) {
      // 视频封面与元信息卡片
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (info.thumbnail.length > 0) {
            Image(info.thumbnail)
              .width(136)
              .height(78)
              .objectFit(ImageFit.Cover)
              .borderRadius(14)
          } else {
            Column() {
              SymbolGlyph($r('sys.symbol.film'))
                .fontSize(28)
                .fontColor([this.secondaryText()])
            }
            .width(136)
            .height(78)
            .justifyContent(FlexAlign.Center)
            .borderRadius(14)
            .backgroundColor('#33415555')
          }

          if (info.isLive) {
            Text('LIVE 直播中')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .borderRadius(8)
              .backgroundColor('#EF4444E6')
              .margin(6)
          }
        }

        Column({ space: 6 }) {
          Text(info.title)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryText())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text([
            info.uploader.length > 0 ? info.uploader : '未知频道',
            info.isLive ? '实时直播' : formatDuration(info.durationSeconds),
            info.extractor
          ].join(' · '))
            .fontSize(12)
            .fontColor(this.secondaryText())
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .padding(14)
      .borderRadius(24)
      .backgroundColor(this.cardFallbackBg())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
      .border({ width: 0.8, color: this.cardBorderColor() })

      // 画质选择玻璃卡片
      Column({ space: 10 }) {
        Text(info.isLive ? '选择直播画质' : '选择清晰度')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(info.formats, (fmt: VideoFormatModel, index: number) => {
            Button(fmt.displayLabel)
              .height(34)
              .fontSize(12)
              .fontWeight((!this.audioOnly && this.selectedFormatIdx === index) ? FontWeight.Bold : FontWeight.Normal)
              .fontColor((!this.audioOnly && this.selectedFormatIdx === index) ? '#FFFFFF' : this.primaryText())
              .backgroundColor((!this.audioOnly && this.selectedFormatIdx === index) ? '#1A73E8CC' : this.cardFallbackBg())
              .systemMaterial(
                (!this.audioOnly && this.selectedFormatIdx === index)
                  ? GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop, '#1A73E8B8')
                  : GlassPalette.pillMaterial(this.settings.glassEnabled, this.settings.darkBackdrop)
              )
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.selectedFormatIdx = index;
                this.audioOnly = false;
              })
          }, (fmt: VideoFormatModel, index: number) => `${fmt.formatId}_${index}`)

          if (info.viaBridge || !info.isLive) {
            Button('仅音频 MP3')
              .height(34)
              .fontSize(12)
              .fontWeight(this.audioOnly ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.audioOnly ? '#FFFFFF' : this.primaryText())
              .backgroundColor(this.audioOnly ? '#1A73E8CC' : this.cardFallbackBg())
              .systemMaterial(
                this.audioOnly
                  ? GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop, '#1A73E8B8')
                  : GlassPalette.pillMaterial(this.settings.glassEnabled, this.settings.darkBackdrop)
              )
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.audioOnly = true;
              })
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .borderRadius(24)
      .backgroundColor(this.cardFallbackBg())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
      .border({ width: 0.8, color: this.cardBorderColor() })

      // 直播录制与断点策略玻璃卡片
      if (info.isLive) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.dot_radiowaves_left_and_right'))
              .fontSize(18)
              .fontColor(['#F87171'])
            Text('直播实时录制与断点保存')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryText())
          }

          Text('录制过程中数据按关键帧/分片实时落盘，在「任务」页可随时点击「断点保存片段」或「停止并保存」生成标准可播放视频。')
            .fontSize(12)
            .fontColor(this.secondaryText())

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(LIVE_DURATION_OPTIONS, (opt: DurationOption) => {
              Button(opt.label)
                .height(34)
                .fontSize(12)
                .fontColor(this.liveMaxDurationSec === opt.seconds ? '#FFFFFF' : this.primaryText())
                .backgroundColor(this.liveMaxDurationSec === opt.seconds ? '#1A73E8CC' : this.cardFallbackBg())
                .systemMaterial(
                  this.liveMaxDurationSec === opt.seconds
                    ? GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop, '#1A73E8B8')
                    : GlassPalette.pillMaterial(this.settings.glassEnabled, this.settings.darkBackdrop)
                )
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.liveMaxDurationSec = opt.seconds;
                })
            }, (opt: DurationOption) => `${opt.seconds}`)
          }

          if (info.isYouTube) {
            Row() {
              Text('尝试从直播开头回溯录制（YouTube DVR）')
                .fontSize(13)
                .fontColor(this.primaryText())
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.liveFromStart })
                .onChange((isOn: boolean) => {
                  this.liveFromStart = isOn;
                })
            }
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(24)
        .backgroundColor(this.cardFallbackBg())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
        .border({ width: 0.8, color: this.cardBorderColor() })
      }

      // 主行动按钮
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph(info.isLive ? $r('sys.symbol.record_circle') : $r('sys.symbol.circle_and_arrow_down_fill'))
            .fontSize(20)
            .fontColor(['#FFFFFF'])
          Text(info.isLive ? '开始实时录制直播（支持任意时刻断点保存）' : '立即开始下载')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        }
      }
      .width('100%')
      .height(52)
      .borderRadius(18)
      .backgroundColor(info.isLive ? '#DC2626D9' : '#1A73E8D9')
      .systemMaterial(
        GlassPalette.interactiveGlassMaterial(
          this.settings.glassEnabled,
          this.settings.darkBackdrop,
          info.isLive ? '#DC2626B8' : '#1A73E8B8'
        )
      )
      .onClick(() => {
        this.startDownloadOrRecord();
      })
    }
    .width('100%')
  }

  @Builder
  TasksTabView() {
    Column() {
      Row() {
        this.GlassHeader('录制与任务', `共 ${this.tasks.length} 个任务 · 直播支持任意时间戳断点保存`)
      }
      .padding({ left: 16, right: 16 })

      if (this.tasks.length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.circle_grid_2x2'))
            .fontSize(54)
            .fontColor([this.secondaryText()])
          Text('暂无下载或录制任务')
            .fontSize(15)
            .fontColor(this.secondaryText())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 12 }) {
          ForEach(this.tasks, (task: DownloadTaskModel) => {
            ListItem() {
              this.TaskCard(task)
            }
          }, (task: DownloadTaskModel) => `${task.id}_${this.taskTick}`)

          ListItem() {
            Row().width('100%').height(100 + this.bottomAvoidVp)
          }
        }
        .padding({ left: 16, right: 16 })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TaskCard(task: DownloadTaskModel) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (task.thumbnail.length > 0) {
            Image(task.thumbnail)
              .width(96)
              .height(54)
              .objectFit(ImageFit.Cover)
              .borderRadius(12)
          } else {
            Column() {
              SymbolGlyph($r('sys.symbol.film'))
                .fontSize(22)
                .fontColor([this.secondaryText()])
            }
            .width(96)
            .height(54)
            .justifyContent(FlexAlign.Center)
            .borderRadius(12)
            .backgroundColor('#33415555')
          }

          if (task.isLive) {
            Text('LIVE')
              .fontSize(9)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor(task.status === TaskStatus.RECORDING ? '#EF4444E6' : '#64748BCC')
              .margin(4)
          }
        }

        Column({ space: 4 }) {
          Text(task.title)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryText())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.describeTaskStatus(task))
            .fontSize(12)
            .fontColor(task.status === TaskStatus.ERROR ? '#F87171' : this.secondaryText())
            .maxLines(2)

          if (task.savedFiles.length > 0 && task.status === TaskStatus.RECORDING) {
            Text(`已断点保存 ${task.savedFiles.length} 个可播放片段`)
              .fontSize(11)
              .fontColor(this.accentColor())
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }

      if (task.status === TaskStatus.RUNNING || task.status === TaskStatus.RECORDING || task.status === TaskStatus.FINALIZING) {
        Progress({
          value: task.status === TaskStatus.RUNNING ? task.progress * 100 : 100,
          total: 100,
          type: ProgressType.Linear
        })
          .color(task.status === TaskStatus.RECORDING ? '#EF4444' : this.accentColor())
          .backgroundColor('#FFFFFF24')
          .height(4)
      }

      // 操作栏
      Row({ space: 8 }) {
        if (task.status === TaskStatus.RECORDING) {
          Button('断点保存片段')
            .height(36)
            .fontSize(12)
            .fontColor(this.primaryText())
            .backgroundColor(this.cardFallbackBg())
            .systemMaterial(GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
            .onClick(async () => {
              const saved = await this.engine.splitCheckpoint(
                task,
                this.settings,
                this.filesDir.length > 0 ? this.filesDir : getContext(this).filesDir
              );
              this.taskTick++;
              if (saved !== null) {
                this.showToast('已切分保存可播放视频片段');
              }
            })

          Button('停止并保存')
            .height(36)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor('#DC2626CC')
            .systemMaterial(GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop, '#DC2626B8'))
            .onClick(() => {
              this.engine.stopAndSave(task, this.settings, () => {
                this.taskTick++;
              });
            })
        } else if (task.status === TaskStatus.RUNNING || task.status === TaskStatus.QUEUED) {
          Button('取消')
            .height(34)
            .fontSize(12)
            .fontColor(this.primaryText())
            .backgroundColor(this.cardFallbackBg())
            .onClick(() => {
              this.engine.cancelTask(task, this.settings);
            })
        } else if (task.status === TaskStatus.DONE && task.outputFile.length > 0) {
          Button('导出到文件管理')
            .height(36)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor('#1A73E8CC')
            .systemMaterial(GlassPalette.interactiveGlassMaterial(this.settings.glassEnabled, this.settings.darkBackdrop, '#1A73E8B8'))
            .onClick(async () => {
              try {
                const uri = await this.engine.exportToUserFiles(task.outputFile, getContext(this));
                if (uri !== null) {
                  this.showToast('已导出可播放视频到文件管理');
                }
              } catch (err) {
                this.showToast(`导出失败：${err}`);
              }
            })

          Button('移除')
            .height(36)
            .fontSize(12)
            .fontColor(this.secondaryText())
            .backgroundColor(this.cardFallbackBg())
            .onClick(() => {
              this.tasks = this.tasks.filter((item: DownloadTaskModel) => item.id !== task.id);
              this.taskTick++;
            })
        } else {
          Button('移除记录')
            .height(34)
            .fontSize(12)
            .fontColor(this.secondaryText())
            .backgroundColor(this.cardFallbackBg())
            .onClick(() => {
              this.tasks = this.tasks.filter((item: DownloadTaskModel) => item.id !== task.id);
              this.taskTick++;
            })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .padding(14)
    .borderRadius(22)
    .backgroundColor(this.cardFallbackBg())
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
    .border({ width: 0.8, color: this.cardBorderColor() })
  }

  private describeTaskStatus(task: DownloadTaskModel): string {
    switch (task.status) {
      case TaskStatus.QUEUED:
        return `${task.qualityLabel} · 排队中…`;
      case TaskStatus.RUNNING:
        return `${task.qualityLabel} · ${(task.progress * 100).toFixed(1)}% · ${task.speedText}`;
      case TaskStatus.RECORDING:
        return `${task.qualityLabel} · 第${task.segmentIndex}段 · 已录 ${task.recordedDuration} · ${task.recordedSize} · ${task.bitrateText}`;
      case TaskStatus.FINALIZING:
        return `${task.qualityLabel} · 正在写入可播放索引…`;
      case TaskStatus.DONE:
        return task.savedFiles.length > 1
          ? `${task.qualityLabel} · 已保存 ${task.savedFiles.length} 个可播放视频`
          : `${task.qualityLabel} · 已保存（${task.recordedSize !== '0 B' ? task.recordedSize : '完成'}）`;
      case TaskStatus.ERROR:
        return task.errorMessage.length > 0 ? task.errorMessage : '下载/录制失败';
      case TaskStatus.CANCELED:
        return `${task.qualityLabel} · 已取消`;
    }
  }

  @Builder
  SettingsTabView() {
    Scroll() {
      Column({ space: 14 }) {
        this.GlassHeader('设置', '鸿蒙 7 原生液态玻璃与直播录制引擎配置')

        // 鸿蒙 7 玻璃效果设置卡片
        Column({ space: 12 }) {
          Text('视觉与鸿蒙 7 玻璃质感')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accentColor())

          Row() {
            Column({ space: 2 }) {
              Text('鸿蒙 7 原生 ImmersiveMaterial 玻璃效果')
                .fontSize(14)
                .fontColor(this.primaryText())
              Text(`设备算力等级：${GlassPalette.getGlobalMaterialLevel()}`)
                .fontSize(11)
                .fontColor(this.secondaryText())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.settings.glassEnabled })
              .onChange((v: boolean) => {
                this.settings = {
                  bridgeUrl: this.settings.bridgeUrl,
                  proxyUrl: this.settings.proxyUrl,
                  biliSessData: this.settings.biliSessData,
                  preferFmp4Live: this.settings.preferFmp4Live,
                  glassEnabled: v,
                  darkBackdrop: this.settings.darkBackdrop
                };
                SettingsStore.save(this.settings);
              })
          }

          Row() {
            Column({ space: 2 }) {
              Text('深色极光背景')
                .fontSize(14)
                .fontColor(this.primaryText())
              Text('增强液态玻璃的折射对比与光感反馈')
                .fontSize(11)
                .fontColor(this.secondaryText())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.settings.darkBackdrop })
              .onChange((v: boolean) => {
                this.settings = {
                  bridgeUrl: this.settings.bridgeUrl,
                  proxyUrl: this.settings.proxyUrl,
                  biliSessData: this.settings.biliSessData,
                  preferFmp4Live: this.settings.preferFmp4Live,
                  glassEnabled: this.settings.glassEnabled,
                  darkBackdrop: v
                };
                SettingsStore.save(this.settings);
              })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(24)
        .backgroundColor(this.cardFallbackBg())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
        .border({ width: 0.8, color: this.cardBorderColor() })

        // Bilibili 直播协议偏好与 Cookie
        Column({ space: 12 }) {
          Text('Bilibili 直播与直连引擎')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accentColor())

          Row() {
            Column({ space: 2 }) {
              Text('优先使用 HLS fMP4 / TS 直播流')
                .fontSize(14)
                .fontColor(this.primaryText())
              Text('断点保存直接生成原生可播 MP4 / TS（关闭则使用 HTTP-FLV）')
                .fontSize(11)
                .fontColor(this.secondaryText())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.settings.preferFmp4Live })
              .onChange((v: boolean) => {
                this.settings = {
                  bridgeUrl: this.settings.bridgeUrl,
                  proxyUrl: this.settings.proxyUrl,
                  biliSessData: this.settings.biliSessData,
                  preferFmp4Live: v,
                  glassEnabled: this.settings.glassEnabled,
                  darkBackdrop: this.settings.darkBackdrop
                };
                SettingsStore.save(this.settings);
              })
          }

          Text('B站 SESSDATA（可选，解锁高画质）')
            .fontSize(12)
            .fontColor(this.secondaryText())
          TextInput({ text: this.settings.biliSessData, placeholder: '粘贴 SESSDATA Cookie…' })
            .height(42)
            .fontSize(13)
            .fontColor(this.primaryText())
            .placeholderColor(this.secondaryText())
            .backgroundColor(this.settings.darkBackdrop ? '#0F172A55' : '#FFFFFF88')
            .borderRadius(12)
            .onChange((v: string) => {
              this.settings = {
                bridgeUrl: this.settings.bridgeUrl,
                proxyUrl: this.settings.proxyUrl,
                biliSessData: v,
                preferFmp4Live: this.settings.preferFmp4Live,
                glassEnabled: this.settings.glassEnabled,
                darkBackdrop: this.settings.darkBackdrop
              };
              SettingsStore.save(this.settings);
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(24)
        .backgroundColor(this.cardFallbackBg())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
        .border({ width: 0.8, color: this.cardBorderColor() })

        // YouTube 与全平台协同服务配置
        Column({ space: 10 }) {
          Text('YouTube 直播与 1800+ 站点协同服务')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accentColor())

          Text('在电脑端运行 VDown 仓库自带的 tools/vdown_bridge.py 后填入局域网地址，即可在鸿蒙端控制 YouTube 直播实时录制、断点切分并回传 MP4。')
            .fontSize(12)
            .fontColor(this.secondaryText())

          TextInput({ text: this.settings.bridgeUrl, placeholder: '例如 http://192.168.1.100:8765' })
            .height(44)
            .fontSize(13)
            .fontColor(this.primaryText())
            .placeholderColor(this.secondaryText())
            .backgroundColor(this.settings.darkBackdrop ? '#0F172A55' : '#FFFFFF88')
            .borderRadius(12)
            .onChange((v: string) => {
              this.settings = {
                bridgeUrl: v,
                proxyUrl: this.settings.proxyUrl,
                biliSessData: this.settings.biliSessData,
                preferFmp4Live: this.settings.preferFmp4Live,
                glassEnabled: this.settings.glassEnabled,
                darkBackdrop: this.settings.darkBackdrop
              };
              SettingsStore.save(this.settings);
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(24)
        .backgroundColor(this.cardFallbackBg())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .systemMaterial(GlassPalette.cardMaterial(this.settings.glassEnabled, this.settings.darkBackdrop))
        .border({ width: 0.8, color: this.cardBorderColor() })

        Blank().height(100 + this.bottomAvoidVp)
      }
      .padding({ left: 16, right: 16 })
      .width('100%')
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      this.AmbientBackdrop()

      HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.currentTab }) {
        TabContent() {
          this.DownloadTabView()
        }
        .tabBar(
          new BottomTabBarStyle($r('sys.symbol.circle_and_arrow_down_fill'), '下载')
            .labelStyle({
              unselectedColor: this.secondaryText(),
              selectedColor: this.accentColor()
            })
        )

        TabContent() {
          this.TasksTabView()
        }
        .tabBar(
          new BottomTabBarStyle($r('sys.symbol.list_bullet'), '任务')
            .labelStyle({
              unselectedColor: this.secondaryText(),
              selectedColor: this.accentColor()
            })
        )

        TabContent() {
          this.SettingsTabView()
        }
        .tabBar(
          new BottomTabBarStyle($r('sys.symbol.gearshape_fill'), '设置')
            .labelStyle({
              unselectedColor: this.secondaryText(),
              selectedColor: this.accentColor()
            })
        )
      }
      .barFloatingStyle({
        barBottomMargin: Math.max(12, this.bottomAvoidVp),
        barSideMargin: 20,
        systemMaterialEffect: {
          materialType: GlassPalette.hdsTabMaterial(this.settings.glassEnabled),
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .onChange((index: number) => {
        this.currentTab = index;
      })
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
