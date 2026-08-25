/**
 * 智护同行 - 跨设备协同与语音触达
 *
 * 对应"手机完成预约、手表提醒出发、耳机语音播报导航"这一核心卖点。
 * 订阅事件总线的 SPEAK / DEVICE_NOTIFY 事件，把逻辑层的意图翻译成设备动作。
 *
 * ⚠️ 分布式流转与穿戴设备通信的具体 API 以 HarmonyOS 官方文档为准，
 * 本文件已把设备侧调用集中在 dispatch() 一处，替换真实实现时只改这里。
 */

import { BusEvent, BusMessage, DeviceNotifyCmd, ReminderItem } from '../core/AgentTypes';
import { eventBus } from '../core/EventBus';
import { notificationManager } from '@kit.NotificationKit';
import { textToSpeech } from '@kit.CoreSpeechKit';


export class DeviceSyncService {
  private static started: boolean = false;
  private static timers: number[] = [];
  private static ttsEngine: textToSpeech.TextToSpeechEngine | null = null;   // ← 新增
  private static ttsReady: boolean = false;
  /** App 启动时调用一次，挂上事件监听 */
  static start(): void {
    if (DeviceSyncService.started) {
      return;
    }
    DeviceSyncService.started = true;

    eventBus.on(BusEvent.SPEAK, (msg: BusMessage) => {
      try {
        const obj: Record<string, string> = JSON.parse(msg.payload) as Record<string, string>;
        DeviceSyncService.speak(obj['text']);
      } catch (e) {
        console.error(`[DeviceSync] speak parse error: ${e}`);
      }
    });

    eventBus.on(BusEvent.DEVICE_NOTIFY, (msg: BusMessage) => {
      try {
        const cmd: DeviceNotifyCmd = JSON.parse(msg.payload) as DeviceNotifyCmd;
        DeviceSyncService.dispatch(cmd);
      } catch (e) {
        console.error(`[DeviceSync] notify parse error: ${e}`);
      }
    });
  }

  /**
   * 设备分发：按 device + channel 选择触达方式
   * phone/card     → 通知卡片
   * watch/vibrate  → 手表震动提醒（走分布式流转）
   * earphone/voice → 耳机语音播报
   */
  private static dispatch(cmd: DeviceNotifyCmd): void {
    console.info(`[DeviceSync] → ${cmd.device}/${cmd.channel}: ${cmd.title}`);

    if (cmd.device === 'watch') {
      DeviceSyncService.notifyWatch(cmd);
      return;
    }
    if (cmd.device === 'earphone') {
      DeviceSyncService.speak(cmd.content);
      return;
    }
    DeviceSyncService.showCard(cmd);
  }

  /** 手机通知卡片 */
  private static showCard(cmd: DeviceNotifyCmd): void {
    const request: notificationManager.NotificationRequest = {
      id: Date.now() % 100000,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: cmd.title,
          text: cmd.content
        }
      }
    };
    notificationManager.publish(request).catch((err: Error) => {
      console.error(`[DeviceSync] publish failed: ${err.message}`);
    });
  }

  /**
   * 手表震动提醒
   * 真实实现：通过分布式软总线把提醒流转到已配对的穿戴设备，
   * 由手表侧应用接收后触发震动 + 大字提示
   */
  private static notifyWatch(cmd: DeviceNotifyCmd): void {
    console.info(`[DeviceSync] watch vibrate: ${cmd.content}`);
    // TODO: 接入分布式流转 API，把 cmd 发送到手表侧 Ability
    // 降级策略：手表不可用时退回手机通知，保证提醒不丢失
    DeviceSyncService.showCard(cmd);
  }

  /**
   * 初始化语音合成引擎，App 启动时调用一次
   * 失败不影响其它功能，只是没声音而已，所以这里吞掉异常不往上抛
   */
  static async initTts(): Promise<void> {
    if (DeviceSyncService.ttsEngine !== null) {
      return;
    }
    try {
      const extraParam: Record<string, Object> = {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'name': 'EngineName'
      };
      const params: textToSpeech.CreateEngineParams = {
        language: 'zh-CN',
        person: 0,        // 音色，0 为默认音色
        online: 0,        // 0=离线合成，不依赖网络，老人场景更稳
        extraParams: extraParam
      };
      DeviceSyncService.ttsEngine = await textToSpeech.createEngine(params);
      DeviceSyncService.ttsReady = true;
      console.info('[TTS] engine ready');
    } catch (e) {
      DeviceSyncService.ttsReady = false;
      console.error(`[TTS] init failed, 将只打印日志不发声: ${e}`);
    }
  }

  /**
   * 语音播报 —— 老年模式：语速放慢、音量调高
   * 引擎不可用时降级为只打印日志，不会导致崩溃
   */
  static speak(text: string): void {
    if (text === undefined || text.length === 0) {
      return;
    }
    console.info(`[TTS] ${text}`);

    if (!DeviceSyncService.ttsReady || DeviceSyncService.ttsEngine === null) {
      return;
    }

    try {
      const extraParam: Record<string, Object> = {
        'queueMode': 0,        // 0=打断当前播报，避免多条提醒排队积压
        'speed': 0.8,          // 语速放慢到 0.8 倍，老人听得清
        'volume': 2,           // 音量调高
        'pitch': 1,
        'languageContext': 'zh-CN',
        'audioType': 'ad',
        'soundChannel': 3,
        'playType': 1
      };
      const speakParams: textToSpeech.SpeakParams = {
        requestId: `tts_${Date.now()}`,
        extraParams: extraParam
      };
      DeviceSyncService.ttsEngine.speak(text, speakParams);
    } catch (e) {
      console.error(`[TTS] speak failed: ${e}`);
    }
  }

  /** App 退出时释放引擎 */
  static releaseTts(): void {
    if (DeviceSyncService.ttsEngine !== null) {
      try {
        DeviceSyncService.ttsEngine.shutdown();
      } catch (e) {
        console.error(`[TTS] shutdown failed: ${e}`);
      }
      DeviceSyncService.ttsEngine = null;
      DeviceSyncService.ttsReady = false;
    }
  }

  /**
   * 注册全流程提醒：把 ReminderAgent 产出的提醒项挂上定时器
   * 生产环境应使用后台代理提醒能力，保证 App 退到后台仍能触发
   */
  static scheduleReminders(items: ReminderItem[]): void {
    DeviceSyncService.clearReminders();

    const now: number = Date.now();
    for (let i = 0; i < items.length; i++) {
      const item: ReminderItem = items[i];
      const delay: number = item.triggerAt - now;
      if (delay <= 0) {
        continue;
      }
      // 演示期用 setTimeout；正式版改用 reminderAgentManager 后台提醒
      const timerId: number = setTimeout(() => {
        const cmd: DeviceNotifyCmd = {
          device: item.targetDevice,
          channel: item.channel,
          title: item.title,
          content: item.content
        };
        DeviceSyncService.dispatch(cmd);
        item.fired = true;
      }, delay);
      DeviceSyncService.timers.push(timerId);
    }
    console.info(`[DeviceSync] scheduled ${DeviceSyncService.timers.length} reminders`);
  }

  static clearReminders(): void {
    for (let i = 0; i < DeviceSyncService.timers.length; i++) {
      clearTimeout(DeviceSyncService.timers[i]);
    }
    DeviceSyncService.timers = [];
  }
}
