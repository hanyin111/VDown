import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';

/**
 * 鸿蒙 7（API 26）原生液态玻璃 / 沉浸式材质工具集。
 * 优先使用 @kit.ArkUI 的 uiMaterial.ImmersiveMaterial（支持光感反馈与交互形变），
 * 并配合 BlurStyle 作为跨设备/预览器降级兜底。
 */
export class GlassPalette {
  static isImmersiveSupported(): boolean {
    try {
      return uiMaterial.isImmersiveMaterialSupported();
    } catch (_err) {
      return false;
    }
  }

  static getGlobalMaterialLevel(): string {
    try {
      const level = uiMaterial.getGlobalMaterialLevel();
      if (level === uiMaterial.MaterialLevel.EXQUISITE) {
        return 'EXQUISITE（高算力液态玻璃）';
      }
      if (level === uiMaterial.MaterialLevel.GENTLE) {
        return 'GENTLE（中算力沉浸玻璃）';
      }
      return 'SMOOTH（轻算力玻璃）';
    } catch (_err) {
      return '预览/兼容模式（BlurStyle 降级）';
    }
  }

  static cardMaterial(enabled: boolean, isDark: boolean): uiMaterial.Material | undefined {
    if (!enabled || !GlassPalette.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      materialColor: isDark ? '#1A1E2E4D' : '#FFFFFF66',
      colorInvert: false,
      applyShadow: true,
      interactive: false,
      lightEffect: {
        color: isDark ? '#8AB4F8' : '#FFFFFF'
      }
    });
  }

  static interactiveGlassMaterial(enabled: boolean, isDark: boolean, tintHex?: string): uiMaterial.Material | undefined {
    if (!enabled || !GlassPalette.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: tintHex ?? (isDark ? '#2B355459' : '#FFFFFF80'),
      colorInvert: false,
      applyShadow: true,
      interactive: true,
      lightEffect: {
        color: isDark ? '#A8C7FA' : '#FFFFFF'
      }
    });
  }

  static pillMaterial(enabled: boolean, isDark: boolean): uiMaterial.Material | undefined {
    if (!enabled || !GlassPalette.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: isDark ? '#24304C52' : '#EEF4FF73',
      colorInvert: false,
      applyShadow: false,
      interactive: true,
      lightEffect: {
        color: '#8AB4F8'
      }
    });
  }

  static hdsTabMaterial(enabled: boolean): hdsMaterial.MaterialType {
    return enabled ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.NONE;
  }
}
