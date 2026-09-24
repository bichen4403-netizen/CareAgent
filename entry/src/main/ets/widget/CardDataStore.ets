/**
 * 智护同行 - 桌面卡片数据
 *
 * 卡片进程与主应用进程分开，用 Preferences 作进程间数据桥：
 *   主应用：确认 / 取消安排时 writeSnapshot()，保存完整时间线并立即推送刷新
 *   卡片：  每次刷新时 readSnapshotSync()，按“当前时间”算出下一步该做什么
 * 这样卡片不需要主应用在后台存活，也能随时间推进自动显示“出发 → 到院 → 候诊”。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { formProvider, formBindingData } from '@kit.FormKit';
import { JourneyRecord, ReminderItem, ReminderKind } from '../core/AgentTypes';
import { DateUtil } from '../core/DateUtil';

const CARD_STORE: string = 'zht_card';
const KEY_SNAPSHOT: string = 'snapshot';
const KEY_FORM_IDS: string = 'form_ids';

/** 就诊结束 12 小时后卡片回到空态 */
const FINISHED_AFTER_MS: number = 12 * 3600 * 1000;

export interface CardStep {
  ts: number;
  label: string;
}

/** 卡片快照：只存卡片需要的字段 */
export interface CardSnapshot {
  hasPlan: boolean;
  hospital: string;
  department: string;
  visitDate: string;
  visitTime: string;
  room: string;
  steps: CardStep[];
  updatedAt: number;
}

export class CardDataStore {

  static emptySnapshot(): CardSnapshot {
    const s: CardSnapshot = {
      hasPlan: false,
      hospital: '',
      department: '',
      visitDate: '',
      visitTime: '',
      room: '',
      steps: [],
      updatedAt: Date.now()
    };
    return s;
  }

  private static labelOf(kind: string): string {
    if (kind === ReminderKind.PREPARE) {
      return '备好证件';
    }
    if (kind === ReminderKind.DEPART_SOON) {
      return '准备出门';
    }
    if (kind === ReminderKind.DEPART) {
      return '出发去医院';
    }
    if (kind === ReminderKind.ARRIVE) {
      return '到院引导';
    }
    if (kind === ReminderKind.QUEUE) {
      return '候诊叫号';
    }
    if (kind === ReminderKind.MEDICATION) {
      return '按新处方吃药';
    }
    if (kind === ReminderKind.POST_VISIT) {
      return '记录复诊时间';
    }
    return '提醒';
  }

  /** 已确认的行程 → 卡片快照（null 表示没有进行中的安排） */
  static fromJourney(j: JourneyRecord | null): CardSnapshot {
    if (j === null) {
      return CardDataStore.emptySnapshot();
    }
    const a = j.appointment;
    const steps: CardStep[] = [];
    for (let i = 0; i < j.reminders.length; i++) {
      const r: ReminderItem = j.reminders[i];
      steps.push({ ts: r.triggerAt, label: CardDataStore.labelOf(r.kind) });
    }
    const visitTs: number = DateUtil.toTimestamp(a.visitDate, a.visitTime);
    if (!isNaN(visitTs)) {
      steps.push({ ts: visitTs, label: `看医生（${a.roomNo}）` });
    }
    steps.sort((x: CardStep, y: CardStep) => x.ts - y.ts);
    const s: CardSnapshot = {
      hasPlan: true,
      hospital: a.hospitalName,
      department: a.department,
      visitDate: a.visitDate,
      visitTime: a.visitTime,
      room: `${a.floor}${a.roomNo}`,
      steps: steps,
      updatedAt: Date.now()
    };
    return s;
  }

  /** 按当前时间计算卡片要显示的内容；字段名与 CareCard.ets 的 @LocalStorageProp 一一对应 */
  static computeView(s: CardSnapshot, nowTs: number): Record<string, Object> {
    const view: Record<string, Object> = {
      'hasPlan': false,
      'title': '还没有陪诊安排',
      'nextAction': '点一下，说句话就能安排',
      'later': '',
      'hospital': '',
      'stepIndex': 0,
      'stepTotal': 0
    };
    if (!s.hasPlan) {
      return view;
    }
    const visitTs: number = DateUtil.toTimestamp(s.visitDate, s.visitTime);
    if (isNaN(visitTs) || nowTs > visitTs + FINISHED_AFTER_MS) {
      view['title'] = '这次陪诊已经结束';
      view['nextAction'] = '点一下，记下医生说的复诊时间';
      return view;
    }
    let idx: number = -1;
    for (let i = 0; i < s.steps.length; i++) {
      if (s.steps[i].ts >= nowTs - 10 * 60 * 1000) {
        idx = i;
        break;
      }
    }
    view['hasPlan'] = true;
    view['title'] = `${DateUtil.friendlyDate(s.visitDate, nowTs)} ${s.visitTime} ${s.department}`;
    view['hospital'] = `${s.hospital} ${s.room}`;
    view['stepTotal'] = s.steps.length;
    if (idx < 0) {
      view['nextAction'] = '今天的陪诊快结束了';
      view['stepIndex'] = s.steps.length;
      return view;
    }
    const cur: CardStep = s.steps[idx];
    view['nextAction'] = `${DateUtil.friendlyTime(cur.ts, nowTs)} ${cur.label}`;
    view['stepIndex'] = idx + 1;
    const later: string[] = [];
    for (let i = idx + 1; i < s.steps.length && later.length < 2; i++) {
      later.push(`${DateUtil.formatHm(s.steps[i].ts)} ${s.steps[i].label}`);
    }
    view['later'] = later.length > 0 ? `接下来：${later.join(' · ')}` : '';
    return view;
  }

  // ==================== 写入（主应用侧） ====================

  static async writeSnapshot(ctx: common.Context, snapshot: CardSnapshot): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, CARD_STORE);
      await store.put(KEY_SNAPSHOT, JSON.stringify(snapshot));
      await store.flush();
    } catch (e) {
      console.error(`[CardDataStore] write failed: ${e}`);
      return;
    }
    await CardDataStore.pushRefresh(ctx, snapshot);
  }

  private static async pushRefresh(ctx: common.Context, snapshot: CardSnapshot): Promise<void> {
    const ids: string[] = CardDataStore.readFormIds(ctx);
    if (ids.length === 0) {
      return;
    }
    const data: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(CardDataStore.computeView(snapshot, Date.now()));
    for (let i = 0; i < ids.length; i++) {
      try {
        await formProvider.updateForm(ids[i], data);
      } catch (e) {
        console.error(`[CardDataStore] refresh ${ids[i]} failed: ${e}`);
      }
    }
  }

  // ==================== 读取（卡片侧） ====================

  /**
   * 卡片进程读取快照。先移除进程内缓存，确保读到主应用刚写入的最新数据。
   */
  static readSnapshotSync(ctx: common.Context): CardSnapshot {
    try {
      preferences.removePreferencesFromCacheSync(ctx, CARD_STORE);
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: CARD_STORE });
      const raw: preferences.ValueType = store.getSync(KEY_SNAPSHOT, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return CardDataStore.emptySnapshot();
      }
      const s: CardSnapshot = JSON.parse(raw) as CardSnapshot;
      if (!Array.isArray(s.steps)) {
        s.steps = [];
      }
      return s;
    } catch (e) {
      console.error(`[CardDataStore] readSync failed: ${e}`);
      return CardDataStore.emptySnapshot();
    }
  }

  // ==================== formId 管理 ====================

  static rememberFormId(ctx: common.Context, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    const ids: string[] = CardDataStore.readFormIds(ctx);
    if (ids.indexOf(formId) < 0) {
      ids.push(formId);
      CardDataStore.writeFormIds(ctx, ids);
    }
  }

  static forgetFormId(ctx: common.Context, formId: string): void {
    const ids: string[] = CardDataStore.readFormIds(ctx);
    const out: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== formId) {
        out.push(ids[i]);
      }
    }
    CardDataStore.writeFormIds(ctx, out);
  }

  private static readFormIds(ctx: common.Context): string[] {
    try {
      preferences.removePreferencesFromCacheSync(ctx, CARD_STORE);
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: CARD_STORE });
      const raw: preferences.ValueType = store.getSync(KEY_FORM_IDS, '[]');
      const v: Object = JSON.parse(typeof raw === 'string' ? raw : '[]') as Object;
      return Array.isArray(v) ? v as string[] : [];
    } catch (e) {
      console.error(`[CardDataStore] read form ids failed: ${e}`);
      return [];
    }
  }

  private static writeFormIds(ctx: common.Context, ids: string[]): void {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: CARD_STORE });
      store.putSync(KEY_FORM_IDS, JSON.stringify(ids));
      store.flush().catch((err: Error) => {
        console.error(`[CardDataStore] flush form ids failed: ${err.message}`);
      });
    } catch (e) {
      console.error(`[CardDataStore] write form ids failed: ${e}`);
    }
  }
}
