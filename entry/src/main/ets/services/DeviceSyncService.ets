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
import { reminderAgentManager } from '@kit.BackgroundTasksKit';

/** 一条已排期的提醒：前台定时器 + 系统级代理提醒 ID 的对应关系 */
interface ScheduledEntry {
  timerId: number;
  reminderId: number;   // -1 表示系统代理提醒未成功发布（权限缺失等），仅前台定时器生效
}

export class DeviceSyncService {
  private static started: boolean = false;
  private static scheduled: ScheduledEntry[] = [];
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
   * 注册全流程提醒：双通道排期
   *  1) setTimeout —— App 存活时的前台通道，走完整 dispatch（择设备/语音播报/卡片）
   *  2) reminderAgentManager —— 系统级后台代理提醒，即使 App 进程被系统杀掉，
   *     到点后系统也会以通知形式弹出提醒，保证"主动提醒"这个核心功能不因进程回收而失效。
   * 两者同时注册：App 在前台时体验更丰富（语音+震动择优），被杀后台后至少还有系统兜底通知。
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

      DeviceSyncService.publishAgentReminder(item, delay, timerId);
    }
    console.info(`[DeviceSync] scheduled ${items.length} reminders`);
  }

  /**
   * 发布系统级代理提醒（后台兜底通道）
   * 需要 module.json5 中声明并已在运行时授予 ohos.permission.PUBLISH_AGENT_REMINDER 权限，
   * 未授权或设备不支持时静默失败，不影响上面的前台 setTimeout 通道。
   */
  private static async publishAgentReminder(item: ReminderItem, delay: number, timerId: number): Promise<void> {
    let reminderId: number = -1;
    try {
      const numericId: number = parseInt(item.id.replace(/\D/g, ''), 10) || (Date.now() % 100000);
      const request: reminderAgentManager.ReminderRequestTimer = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
        triggerTimeInSeconds: Math.max(1, Math.ceil(delay / 1000)),
        title: item.title,
        content: item.content,
        notificationId: numericId,
        ringDuration: 5
      };
      reminderId = await reminderAgentManager.publishReminder(request);
    } catch (e) {
      // 权限未授予 / 设备不支持等情况下静默降级：仅前台 setTimeout 通道生效
      console.error(`[DeviceSync] publishReminder failed, 仅前台生效: ${e}`);
    }
    const entry: ScheduledEntry = { timerId: timerId, reminderId: reminderId };
    DeviceSyncService.scheduled.push(entry);
  }

  static clearReminders(): void {
    for (let i = 0; i < DeviceSyncService.scheduled.length; i++) {
      const entry: ScheduledEntry = DeviceSyncService.scheduled[i];
      clearTimeout(entry.timerId);
      if (entry.reminderId >= 0) {
        reminderAgentManager.cancelReminder(entry.reminderId).catch((e: Error) => {
          console.error(`[DeviceSync] cancelReminder failed: ${e.message}`);
        });
      }
    }
    DeviceSyncService.scheduled = [];
  }
}
