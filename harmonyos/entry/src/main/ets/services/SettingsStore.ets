import { preferences } from '@kit.ArkData';
import { AppSettingsModel } from '../models/VDownModels';

const PREF_NAME = 'vdown_settings';

export class SettingsStore {
  private static pref: preferences.Preferences | null = null;

  static async load(context: Context): Promise<AppSettingsModel> {
    try {
      SettingsStore.pref = await preferences.getPreferences(context, PREF_NAME);
      const p = SettingsStore.pref;
      return {
        bridgeUrl: (await p.get('bridgeUrl', '')) as string,
        proxyUrl: (await p.get('proxyUrl', '')) as string,
        biliSessData: (await p.get('biliSessData', '')) as string,
        preferFmp4Live: (await p.get('preferFmp4Live', true)) as boolean,
        glassEnabled: (await p.get('glassEnabled', true)) as boolean,
        darkBackdrop: (await p.get('darkBackdrop', true)) as boolean,
      };
    } catch (_err) {
      return {
        bridgeUrl: '',
        proxyUrl: '',
        biliSessData: '',
        preferFmp4Live: true,
        glassEnabled: true,
        darkBackdrop: true,
      };
    }
  }

  static async save(settings: AppSettingsModel): Promise<void> {
    if (!SettingsStore.pref) {
      return;
    }
    try {
      await SettingsStore.pref.put('bridgeUrl', settings.bridgeUrl);
      await SettingsStore.pref.put('proxyUrl', settings.proxyUrl);
      await SettingsStore.pref.put('biliSessData', settings.biliSessData);
      await SettingsStore.pref.put('preferFmp4Live', settings.preferFmp4Live);
      await SettingsStore.pref.put('glassEnabled', settings.glassEnabled);
      await SettingsStore.pref.put('darkBackdrop', settings.darkBackdrop);
      await SettingsStore.pref.flush();
    } catch (_err) {
      // ignore persistence errors
    }
  }
}
