/**
 * 智护同行 - 应用入口
 *
 * 启动时装配端侧存储、模型实现与语音服务（AppBootstrap），不在启动时申请权限。
 * 从提醒通知或桌面卡片进入时，want.parameters.target 指明要打开的页面：
 *   journey → 陪诊安排    nav → 院内引导    home → 首页
 * 页面通过 AppStorage 的 pendingRoute 获知并跳转（冷启动与热启动走同一套逻辑）。
 */

import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppBootstrap, ROUTE_KEY } from '../core/AppBootstrap';
import { DeviceSyncService } from '../services/DeviceSyncService';
import { SpeechInputService } from '../services/SpeechInputService';
import { OcrCaptureService } from '../services/OcrCaptureService';

export default class EntryAbility extends UIAbility {

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[EntryAbility] onCreate');
    EntryAbility.saveRoute(want);
    AppBootstrap.start(this.context).catch((e: Error) => {
      console.error(`[EntryAbility] bootstrap failed: ${e.message}`);
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[EntryAbility] onNewWant');
    EntryAbility.saveRoute(want);
  }

  /** 读取提醒/卡片携带的目标页面，写入 AppStorage 供首页跳转 */
  private static saveRoute(want: Want): void {
    let target: string = '';
    if (want.parameters !== undefined) {
      const v: Object | undefined = want.parameters['target'];
      target = typeof v === 'string' ? v : '';
    }
    if (target === 'journey' || target === 'nav' || target === 'home') {
      // 追加时间戳：同一目标连续触发两次也能被页面感知
      AppStorage.setOrCreate<string>(ROUTE_KEY, `${target}#${Date.now()}`);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err && err.code) {
        console.error(`[EntryAbility] loadContent failed: ${err.code} ${err.message}`);
        return;
      }
      console.info('[EntryAbility] content loaded');
    });
  }

  onWindowStageDestroy(): void {
    SpeechInputService.cancel();
  }

  onForeground(): void {
    console.info('[EntryAbility] onForeground');
  }

  onBackground(): void {
    // 退到后台时停止录音与播报，避免后台占用麦克风
    SpeechInputService.cancel();
    DeviceSyncService.stopSpeaking();
  }

  onDestroy(): void {
    SpeechInputService.release();
    DeviceSyncService.releaseTts();
    OcrCaptureService.release().catch((e: Error) => {
      console.warn(`[EntryAbility] ocr release failed: ${e.message}`);
    });
  }
}
