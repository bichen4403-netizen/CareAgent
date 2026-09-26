/**
 * 智护同行 - 启动装配
 *
 * 在 EntryAbility.onCreate 中启动，页面通过 ready() 等待完成后再读取端侧数据：
 *   1. 按配置注入大模型 / OCR 实现（未配置网关时使用离线规则）
 *   2. 打开端侧存储（档案、病历、行程），首次运行写入演示数据
 *   3. 初始化语音播报与提醒服务，同步桌面卡片
 * 不在启动时申请任何权限，权限在用到时再按需申请。
 */

import { common } from '@kit.AbilityKit';
import { BackendConfig } from '../config/BackendConfig';
import { LLMService, HttpLLMProvider } from '../services/LLMService';
import { OcrCaptureService, SystemOcrProvider } from '../services/OcrCaptureService';
import { DeviceSyncService } from '../services/DeviceSyncService';
import { ContextStore } from './ContextStore';
import { JourneyStore } from './JourneyStore';
import { CardDataStore } from '../widget/CardDataStore';

/** AppStorage 键：从提醒/卡片进入时要打开的页面，格式 target#时间戳 */
export const ROUTE_KEY: string = 'pendingRoute';

export class AppBootstrap {
  private static readyPromise: Promise<void> | null = null;

  static start(ctx: common.UIAbilityContext): Promise<void> {
    if (AppBootstrap.readyPromise === null) {
      AppBootstrap.readyPromise = AppBootstrap.doStart(ctx);
    }
    return AppBootstrap.readyPromise;
  }

  /** 页面在读取端侧数据前等待；若 Ability 尚未启动装配则立即返回 */
  static ready(): Promise<void> {
    return AppBootstrap.readyPromise !== null ? AppBootstrap.readyPromise : Promise.resolve();
  }

  private static async doStart(ctx: common.UIAbilityContext): Promise<void> {
    if (BackendConfig.enabled()) {
      LLMService.setProvider(new HttpLLMProvider(`${BackendConfig.baseUrl()}/v1/llm/chat`, '', '', true,
        'deepseek-gateway'));
      console.info('[Bootstrap] LLM via backend gateway');
    } else {
      console.info('[Bootstrap] BASE_URL 未配置，使用离线规则理解 + 演示数据');
    }
    OcrCaptureService.setProvider(new SystemOcrProvider());
    DeviceSyncService.init(ctx);

    try {
      await ContextStore.getInstance().init(ctx);
      await JourneyStore.getInstance().init(ctx);
      await ContextStore.getInstance().ensureDemoSeed(Date.now());
      await CardDataStore.writeSnapshot(ctx, CardDataStore.fromJourney(JourneyStore.getInstance().getActive()));
    } catch (e) {
      console.error(`[Bootstrap] init storage failed: ${e}`);
    }
  }
}
