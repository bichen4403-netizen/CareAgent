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
 * 已改为 DeepSeek（OpenAI 兼容格式），去 platform.deepseek.com 注册后
 * 在"API Keys"页面创建一个 Key，把下面 LLM_TOKEN 换成你自己的。
 * LLM_ENDPOINT 和 LLM_MODEL 不用改，DeepSeek 固定就是这两个值。
 *
 * 也可以换成小艺开放平台提供的模型接口、通义千问、讯飞星火等，
 * 只要是 OpenAI 兼容格式（messages/choices结构），endpoint 和 model 换掉即可。
 * 留空则自动使用离线 Mock Provider，保证演示不依赖网络。
 */
const LLM_ENDPOINT: string = 'https://api.deepseek.com/chat/completions';
const LLM_TOKEN: string = '把你申请到的 DeepSeek API Key 粘贴到这里，形如 sk-xxxxxxxxxxxx';
const LLM_MODEL: string = 'deepseek-chat';

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
    if (LLM_ENDPOINT.length > 0) {
      LLMService.setProvider(new HttpLLMProvider(LLM_ENDPOINT, LLM_TOKEN, LLM_MODEL));
      console.info('[EntryAbility] LLM provider: HTTP');
    } else {
      console.info('[EntryAbility] LLM provider: Mock (offline)');
    }

    // 跨设备协同服务
    DeviceSyncService.start();

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
