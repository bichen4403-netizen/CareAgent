/**
 * 智护同行 - 多端触达与语音播报
 *
 * 对应“手机完成预约、手表提醒出发、耳机语音播报”这一卖点：
 *   - 全流程提醒交给系统代理提醒（reminderAgentManager），App 退到后台或被回收后仍会准时触发；
 *     系统通知会按用户的设置同步到已配对的手表 / 手环，无需在手表上安装本应用。
 *   - 语音播报使用系统离线语音合成，老年模式放慢语速、调高音量。
 *   - 点击提醒会回到本应用的“陪诊安排”或“院内引导”页面。
 */

import { BusEvent, BusMessage, DeviceNotifyCmd, ReminderItem, ReminderKind } from '../core/AgentTypes';
import { eventBus } from '../core/EventBus';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { textToSpeech } from '@kit.CoreSpeechKit';

export interface ScheduleResult {
  platform: number;     // 成功注册到系统的条数
  local: number;        // 系统注册失败、退回进程内定时器的条数（App 存活时有效）
  skippedPast: number;  // 时间已过、未注册的条数
  failed: number;
}

/** 进程内兜底定时器只接管 6 小时内的提醒，更远的无意义 */
const LOCAL_FALLBACK_WINDOW_MS: number = 6 * 3600 * 1000;

export class DeviceSyncService {
  private static started: boolean = false;
  private static bundleName: string = '';
  private static timers: number[] = [];
  private static notifySeq: number = 1;
  private static ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  private static ttsInit: Promise<void> | null = null;
  private static speaking: boolean = false;
  private static speakSeq: number = 0;

  /** App 启动时调用一次 */
  static init(ctx: common.UIAbilityContext): void {
    DeviceSyncService.bundleName = ctx.abilityInfo.bundleName;
    if (!DeviceSyncService.started) {
      DeviceSyncService.started = true;
      eventBus.on(BusEvent.SPEAK, (msg: BusMessage) => {
        DeviceSyncService.speak(DeviceSyncService.textOf(msg.payload), false);
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
    DeviceSyncService.ensureTts().catch((e: Error) => {
      console.warn(`[TTS] init skipped: ${e.message}`);
    });
  }

  private static textOf(payload: string): string {
    try {
      const obj: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      const t: Object | undefined = obj['text'];
      return typeof t === 'string' ? t : '';
    } catch (e) {
      return '';
    }
  }

  // ==================== 语音播报 ====================

  private static ensureTts(): Promise<void> {
    if (DeviceSyncService.ttsEngine !== null) {
      return Promise.resolve();
    }
    if (DeviceSyncService.ttsInit === null) {
      DeviceSyncService.ttsInit = DeviceSyncService.createTts();
    }
    return DeviceSyncService.ttsInit;
  }

  private static async createTts(): Promise<void> {
    try {
      const extraParam: Record<string, Object> = {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'name': 'ZhiHuTongXingTts'
      };
      const params: textToSpeech.CreateEngineParams = {
        language: 'zh-CN',
        person: 0,
        online: 1,          // 1 = 离线合成（当前系统仅支持离线模式），不依赖网络
        extraParams: extraParam
      };
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      const listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, response: textToSpeech.StartResponse) => {
          DeviceSyncService.speaking = true;
        },
        onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
          DeviceSyncService.speaking = false;
        },
        onStop: (requestId: string, response: textToSpeech.StopResponse) => {
          DeviceSyncService.speaking = false;
        },
        onError: (requestId: string, errorCode: number, errorMessage: string) => {
          DeviceSyncService.speaking = false;
          console.warn(`[TTS] error ${errorCode}: ${errorMessage}`);
        }
      };
      engine.setListener(listener);
      DeviceSyncService.ttsEngine = engine;
      console.info('[TTS] engine ready');
    } catch (e) {
      DeviceSyncService.ttsEngine = null;
      console.error(`[TTS] init failed, 只显示文字不发声: ${e}`);
    } finally {
      DeviceSyncService.ttsInit = null;
    }
  }

  /** 播报文字；interrupt=true 时先停掉正在播的内容（例如用户点了“再听一遍”） */
  static speak(text: string, interrupt: boolean): void {
    const clean: string = DeviceSyncService.forSpeech(text);
    if (clean.length === 0) {
      return;
    }
    console.info(`[TTS] ${clean}`);
    DeviceSyncService.ensureTts().then(() => {
      const engine: textToSpeech.TextToSpeechEngine | null = DeviceSyncService.ttsEngine;
      if (engine === null) {
        return;
      }
      try {
        if (interrupt && engine.isBusy()) {
          engine.stop();
        }
        DeviceSyncService.speakSeq += 1;
        const extraParam: Record<string, Object> = {
          'queueMode': 0,
          'speed': 0.85,        // 老年模式：语速放慢
          'volume': 1.5,        // 音量调高
          'pitch': 1,
          'languageContext': 'zh-CN',
          'audioType': 'pcm',
          'soundChannel': 3,
          'playType': 1
        };
        const speakParams: textToSpeech.SpeakParams = {
          requestId: `zht_${Date.now()}_${DeviceSyncService.speakSeq}`,
          extraParams: extraParam
        };
        engine.speak(clean, speakParams);
      } catch (e) {
        console.error(`[TTS] speak failed: ${e}`);
      }
    }).catch((e: Error) => {
      console.warn(`[TTS] not ready: ${e.message}`);
    });
  }

  static stopSpeaking(): void {
    const engine: textToSpeech.TextToSpeechEngine | null = DeviceSyncService.ttsEngine;
    if (engine === null) {
      return;
    }
    try {
      if (engine.isBusy()) {
        engine.stop();
      }
    } catch (e) {
      console.warn(`[TTS] stop failed: ${e}`);
    }
    DeviceSyncService.speaking = false;
  }

  static isSpeaking(): boolean {
    return DeviceSyncService.speaking;
  }

  /** 去掉不适合朗读的符号与标签 */
  private static forSpeech(text: string): string {
    if (text === undefined || text === null) {
      return '';
    }
    return text.replace(/[【】\[\]]/g, '').replace(/（演示数据）|\(演示数据\)/g, '').trim();
  }

  static releaseTts(): void {
    const engine: textToSpeech.TextToSpeechEngine | null = DeviceSyncService.ttsEngine;
    DeviceSyncService.ttsEngine = null;
    DeviceSyncService.speaking = false;
    if (engine !== null) {
      try {
        engine.shutdown();
      } catch (e) {
        console.error(`[TTS] shutdown failed: ${e}`);
      }
    }
  }

  // ==================== 通知 ====================

  /** 确认开启提醒时调用：未开启通知则拉起系统授权弹窗 */
  static async ensureNotificationEnabled(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(ctx);
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      console.warn(`[DeviceSync] notification not enabled: ${e}`);
      return false;
    }
  }

  /**
   * 设备分发：phone/card → 通知卡片；watch/vibrate → 系统通知（已配对手表自动同步震动）；
   * earphone/voice → 语音播报（连接耳机时从耳机播出）
   */
  private static dispatch(cmd: DeviceNotifyCmd): void {
    console.info(`[DeviceSync] → ${cmd.device}/${cmd.channel}: ${cmd.title}`);
    if (cmd.device === 'earphone') {
      DeviceSyncService.speak(`${cmd.title}。${cmd.content}`, true);
      return;
    }
    DeviceSyncService.showCard(cmd.title, cmd.content);
  }

  private static showCard(title: string, content: string): void {
    DeviceSyncService.notifySeq = DeviceSyncService.notifySeq % 100000 + 1;
    const request: notificationManager.NotificationRequest = {
      id: 90000 + DeviceSyncService.notifySeq,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: content
        }
      }
    };
    notificationManager.publish(request).catch((err: Error) => {
      console.error(`[DeviceSync] publish failed: ${err.message}`);
    });
  }

  // ==================== 全流程提醒 ====================

  /**
   * 注册全流程提醒：先清掉本应用之前注册的全部提醒，避免重复确认导致重复提醒；
   * 已过时间的不注册；系统注册失败的近期提醒退回进程内定时器。
   */
  static async scheduleReminders(items: ReminderItem[]): Promise<ScheduleResult> {
    await DeviceSyncService.cancelAllReminders();
    const result: ScheduleResult = { platform: 0, local: 0, skippedPast: 0, failed: 0 };
    const now: number = Date.now();
    for (let i = 0; i < items.length; i++) {
      const item: ReminderItem = items[i];
      if (item.triggerAt <= now + 30 * 1000) {
        result.skippedPast += 1;
        continue;
      }
      try {
        await DeviceSyncService.publishOne(item);
        result.platform += 1;
      } catch (e) {
        console.warn(`[DeviceSync] platform reminder failed (${item.title}): ${e}`);
        if (item.triggerAt - now <= LOCAL_FALLBACK_WINDOW_MS) {
          DeviceSyncService.scheduleLocal(item);
          result.local += 1;
        } else {
          result.failed += 1;
        }
      }
    }
    console.info(`[DeviceSync] reminders platform=${result.platform} local=${result.local} ` +
      `past=${result.skippedPast} failed=${result.failed}`);
    return result;
  }

  /** 取消本应用注册的全部提醒（系统代理提醒 + 进程内定时器） */
  static async cancelAllReminders(): Promise<void> {
    for (let i = 0; i < DeviceSyncService.timers.length; i++) {
      clearTimeout(DeviceSyncService.timers[i]);
    }
    DeviceSyncService.timers = [];
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (e) {
      console.warn(`[DeviceSync] cancel reminders failed: ${e}`);
    }
  }

  private static async publishOne(item: ReminderItem): Promise<number> {
    const d: Date = new Date(item.triggerAt);
    let target: string = 'journey';
    if (item.kind === ReminderKind.ARRIVE) {
      target = 'nav';
    } else if (item.kind === ReminderKind.POST_VISIT) {
      target = 'home';
    }
    const wantParams: Record<string, Object> = { 'target': target };
    const closeBtn: reminderAgentManager.ActionButton = {
      title: '知道了',
      type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
    };
    const snoozeBtn: reminderAgentManager.ActionButton = {
      title: '10分钟后再提醒',
      type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_SNOOZE
    };
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: d.getFullYear(),
        month: d.getMonth() + 1,
        day: d.getDate(),
        hour: d.getHours(),
        minute: d.getMinutes(),
        second: 0
      },
      title: item.title,
      content: item.content,
      expiredContent: `${item.title}（时间已过）`,
      snoozeContent: `${item.title}（稍后再提醒）`,
      actionButton: [closeBtn, snoozeBtn],
      snoozeTimes: 2,
      timeInterval: 600,
      ringDuration: 10,
      notificationId: DeviceSyncService.notificationIdOf(item)
    };
    if (DeviceSyncService.bundleName.length > 0) {
      req.wantAgent = {
        pkgName: DeviceSyncService.bundleName,
        abilityName: 'EntryAbility',
        parameters: wantParams
      };
    }
    return await reminderAgentManager.publishReminder(req);
  }

  private static notificationIdOf(item: ReminderItem): number {
    let hash: number = 17;
    const key: string = `${item.id}${item.triggerAt}`;
    for (let i = 0; i < key.length; i++) {
      hash = (hash * 31 + key.charCodeAt(i)) % 80000;
    }
    return 10000 + hash;
  }

  private static scheduleLocal(item: ReminderItem): void {
    const delay: number = item.triggerAt - Date.now();
    if (delay <= 0) {
      return;
    }
    const timerId: number = setTimeout(() => {
      const cmd: DeviceNotifyCmd = {
        device: item.targetDevice,
        channel: item.channel,
        title: item.title,
        content: item.content
      };
      DeviceSyncService.dispatch(cmd);
    }, delay);
    DeviceSyncService.timers.push(timerId);
  }
}
