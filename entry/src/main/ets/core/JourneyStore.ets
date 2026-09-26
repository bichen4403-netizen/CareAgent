/**
 * 智护同行 - 陪诊行程持久化
 *
 * 之前方案只存在内存黑板里：老人跳去京医通确认挂号时，App 若被系统回收，
 * 回来就什么都没了；“已确认”状态也只存在页面变量里，退出再进可以重复确认。
 *
 * 现在拆成两个槽位并写入端侧：
 *   draft  —— 最新生成、尚未确认的方案（可被新方案覆盖）
 *   active —— 用户已在官方渠道确认、提醒已开启的方案
 * 新方案确认时才会替换 active，确认前旧提醒照常生效。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { JourneyRecord, JourneyStage, BusEvent, BookingStatus } from './AgentTypes';
import { eventBus } from './EventBus';
import { DateUtil } from './DateUtil';

const STORE_NAME: string = 'zht_journey';
const KEY_DRAFT: string = 'draft';
const KEY_ACTIVE: string = 'active';

/** 就诊时间过后多久开始询问“看完了吗” */
const POST_VISIT_DELAY_MS: number = 2 * 3600 * 1000;

export class JourneyStore {
  private static instance: JourneyStore | null = null;
  private store: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;
  private draft: JourneyRecord | null = null;
  private active: JourneyRecord | null = null;

  static getInstance(): JourneyStore {
    if (JourneyStore.instance === null) {
      JourneyStore.instance = new JourneyStore();
    }
    return JourneyStore.instance;
  }

  async init(ctx: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.load(ctx);
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  private async load(ctx: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(ctx, STORE_NAME);
      this.draft = JourneyStore.parse(await this.read(KEY_DRAFT));
      this.active = JourneyStore.parse(await this.read(KEY_ACTIVE));
      // 已取消/已完成的不再作为“当前行程”展示
      if (this.active !== null &&
        (this.active.stage === JourneyStage.CANCELLED || this.active.stage === JourneyStage.COMPLETED)) {
        this.active = null;
      }
    } catch (e) {
      console.error(`[JourneyStore] load failed: ${e}`);
    }
  }

  getDraft(): JourneyRecord | null {
    return this.draft;
  }

  getActive(): JourneyRecord | null {
    return this.active;
  }

  /** 页面默认展示：有未确认的新方案先展示新方案，否则展示已确认的 */
  getForDisplay(): JourneyRecord | null {
    return this.draft !== null ? this.draft : this.active;
  }

  async saveDraft(j: JourneyRecord): Promise<void> {
    j.stage = JourneyStage.DRAFT;
    j.updatedAt = Date.now();
    this.draft = j;
    await this.write(KEY_DRAFT, JSON.stringify(j));
    this.notifyChanged();
  }

  async markAwaitingOfficial(): Promise<void> {
    if (this.draft === null) {
      return;
    }
    this.draft.stage = JourneyStage.AWAITING_OFFICIAL;
    this.draft.appointment.bookingStatus = BookingStatus.AWAITING_OFFICIAL;
    this.draft.updatedAt = Date.now();
    await this.write(KEY_DRAFT, JSON.stringify(this.draft));
    this.notifyChanged();
  }

  /** 用户确认已在官方渠道挂上号：draft → active。重复调用是安全的。 */
  async promoteDraft(remindersScheduled: number): Promise<JourneyRecord | null> {
    if (this.draft === null) {
      return this.active;
    }
    const j: JourneyRecord = this.draft;
    j.stage = JourneyStage.CONFIRMED;
    j.appointment.bookingStatus = BookingStatus.CONFIRMED;
    j.remindersScheduled = remindersScheduled;
    j.updatedAt = Date.now();
    this.active = j;
    this.draft = null;
    await this.write(KEY_ACTIVE, JSON.stringify(j));
    await this.write(KEY_DRAFT, '');
    this.notifyChanged();
    return j;
  }

  async discardDraft(): Promise<void> {
    this.draft = null;
    await this.write(KEY_DRAFT, '');
    this.notifyChanged();
  }

  async cancelActive(): Promise<void> {
    this.active = null;
    await this.write(KEY_ACTIVE, '');
    this.notifyChanged();
  }

  /** 就诊结束并已记录结果 */
  async completeActive(): Promise<void> {
    this.active = null;
    await this.write(KEY_ACTIVE, '');
    this.notifyChanged();
  }

  async clearAll(): Promise<void> {
    this.draft = null;
    this.active = null;
    await this.write(KEY_DRAFT, '');
    await this.write(KEY_ACTIVE, '');
    this.notifyChanged();
  }

  /** 已确认的行程，就诊时间过去 2 小时后需要询问“看完了吗” */
  needsPostVisitCheck(nowTs: number): JourneyRecord | null {
    const j: JourneyRecord | null = this.active;
    if (j === null || j.stage !== JourneyStage.CONFIRMED) {
      return null;
    }
    const visitTs: number = DateUtil.toTimestamp(j.appointment.visitDate, j.appointment.visitTime);
    if (isNaN(visitTs) || nowTs < visitTs + POST_VISIT_DELAY_MS) {
      return null;
    }
    return j;
  }

  private notifyChanged(): void {
    eventBus.emit(BusEvent.JOURNEY_CHANGED, '');
  }

  private async read(key: string): Promise<string> {
    if (this.store === null) {
      return '';
    }
    try {
      const v: preferences.ValueType = await this.store.get(key, '');
      return typeof v === 'string' ? v : '';
    } catch (e) {
      console.error(`[JourneyStore] read ${key} failed: ${e}`);
      return '';
    }
  }

  private async write(key: string, value: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (e) {
      console.error(`[JourneyStore] write ${key} failed: ${e}`);
    }
  }

  /** 解析并补齐字段：老数据缺字段时不崩溃 */
  private static parse(raw: string): JourneyRecord | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const appt: Object | undefined = obj['appointment'];
      if (appt === undefined || appt === null || typeof appt !== 'object') {
        return null;
      }
      const j: JourneyRecord = JSON.parse(raw) as JourneyRecord;
      if (!Array.isArray(j.reminders)) {
        j.reminders = [];
      }
      if (j.travel === undefined) {
        j.travel = null;
      }
      if (j.nav === undefined) {
        j.nav = null;
      }
      if (j.preparation === undefined || j.preparation === null) {
        j.preparation = { visitItems: [], materials: [], notices: [] };
      }
      if (typeof j.lastPrescription !== 'string') {
        j.lastPrescription = '';
      }
      if (typeof j.remindersScheduled !== 'number') {
        j.remindersScheduled = 0;
      }
      if (typeof j.appointment.hospitalLng !== 'number') {
        j.appointment.hospitalLng = 0;
        j.appointment.hospitalLat = 0;
      }
      return j;
    } catch (e) {
      console.error(`[JourneyStore] corrupted journey, ignore: ${e}`);
      return null;
    }
  }
}
