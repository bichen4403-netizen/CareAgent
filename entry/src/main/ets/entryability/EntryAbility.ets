/**
 * 智护同行 - 应用入口
 *
 * 启动时完成：端侧上下文初始化、LLM Provider 注入、跨设备服务启动、
 * 以及主动服务的后台巡检（扫描到期复诊）。
 */

import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { ContextStore } from '../core/ContextStore';
import { DeviceSyncService } from '../services/DeviceSyncService';
import { LLMService, HttpLLMProvider } from '../services/LLMService';
import { CentralAgent } from '../agents/CentralAgent';

/**
 * ⚠️ 配置项：接入真实大模型
 *
 * 客户端源码中不得保存模型 Token。Demo 默认使用离线 Mock Provider；
 * 后续如需接入真实模型，应通过受控后端代理请求，并在后端保存和轮换密钥。
 * 小艺开放平台通过系统 Agent / Skill 机制接入，不需要在这里配置平台密钥。
 */
const LLM_ENDPOINT: string = '';
const LLM_TOKEN: string = '';
const LLM_MODEL: string = '';

/** 主动服务巡检间隔：4 小时 */
const PROACTIVE_INTERVAL_MS: number = 4 * 3600 * 1000;

export default class EntryAbility extends UIAbility {
  private proactiveTimer: number = -1;
  private central: CentralAgent = new CentralAgent();

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    console.info('[EntryAbility] onCreate');

    // 端侧记忆初始化
    await ContextStore.getInstance().init(this.context);

    // 注入大模型 Provider
    if (LLM_ENDPOINT.length > 0 && LLM_TOKEN.length > 0 && LLM_MODEL.length > 0) {
      LLMService.setProvider(new HttpLLMProvider(LLM_ENDPOINT, LLM_TOKEN, LLM_MODEL));
      console.info('[EntryAbility] LLM provider: HTTP');
    } else {
      console.info('[EntryAbility] LLM provider: Mock (offline)');
    }

    // 跨设备协同服务
    DeviceSyncService.start();
    // 初始化语音合成引擎（失败也不影响其它功能，只是没声音）
    await DeviceSyncService.initTts();
    // 主动服务：定时扫描到期复诊
    this.startProactiveCheck();
  }

  private startProactiveCheck(): void {
    // 启动后先跑一次
    this.central.proactiveCheck(Date.now());
    this.proactiveTimer = setInterval(() => {
      this.central.proactiveCheck(Date.now());
    }, PROACTIVE_INTERVAL_MS);
  }

  onDestroy(): void {
    if (this.proactiveTimer >= 0) {
      clearInterval(this.proactiveTimer);
    }
    DeviceSyncService.clearReminders();
    DeviceSyncService.releaseTts();
    console.info('[EntryAbility] onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`[EntryAbility] loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      console.info('[EntryAbility] loadContent succeeded');
    });
  }

  onForeground(): void {
    // 回到前台立即检查一次，避免用户刚打开就错过提醒
    this.central.proactiveCheck(Date.now());
  }

  onBackground(): void {
    console.info('[EntryAbility] onBackground');
  }
}
