import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'VDown', 'Failed to set colorMode: %{public}s', JSON.stringify(err));
    }
    AppStorage.setOrCreate('vdownFilesDir', this.context.filesDir);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'VDown', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'VDown', 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      try {
        const mainWindow = windowStage.getMainWindowSync();
        mainWindow.setWindowLayoutFullScreen(true);
        const sysArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const navArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const uiCtx = mainWindow.getUIContext();
        AppStorage.setOrCreate('topAvoidVp', uiCtx.px2vp(sysArea.topRect.height));
        AppStorage.setOrCreate('bottomAvoidVp', uiCtx.px2vp(navArea.bottomRect.height));
        mainWindow.on('avoidAreaChange', (data) => {
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            AppStorage.setOrCreate('topAvoidVp', uiCtx.px2vp(data.area.topRect.height));
          } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
            AppStorage.setOrCreate('bottomAvoidVp', uiCtx.px2vp(data.area.bottomRect.height));
          }
        });
      } catch (e) {
        hilog.warn(DOMAIN, 'VDown', 'FullScreen setup skipped: %{public}s', JSON.stringify(e));
      }
    });
  }
}
