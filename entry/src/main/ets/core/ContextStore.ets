/**
 * 智护同行 - 端侧上下文记忆
 *
 * 用户档案、历史服务记录全部存在端侧 Preferences，不上云。
 * 这是“沉淀服务记录 → 下次复诊自动提前规划”的数据基础，也是隐私保护的实现依据：
 * 用户可在“我的”页面查看、删除任意记录，或一键清除全部数据。
 *
 * 读取时逐字段校验：偏好文件损坏或老版本缺字段都不会导致启动崩溃。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  UserProfile, ServiceRecord, RuntimeContext, RecordSource, DemoSettings, FollowUpPrompt
} from './AgentTypes';
import { DateUtil } from './DateUtil';

const STORE_NAME: string = 'zht_context';
const KEY_PROFILE: string = 'user_profile';
const KEY_RECORDS: string = 'service_records';
const KEY_PROMPTED: string = 'followup_prompted';
const KEY_DEMO: string = 'demo_settings';
const KEY_SEED: string = 'demo_seed_version';

/** 演示数据版本：v2 起演示病历的就诊日期按“今天”动态生成，保证主动复诊提醒可演示 */
const SEED_VERSION: number = 2;
const DEMO_RECORD_ID: string = 'r001';
const DISMISSED: string = 'DISMISSED';

/** 复诊窗口：到期前 3 天开始询问，逾期 7 天内仍会提醒 */
const FOLLOW_UP_ADVANCE_DAYS: number = 3;
const FOLLOW_UP_OVERDUE_DAYS: number = 7;

export class ContextStore {
  private static instance: ContextStore | null = null;
  private store: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;
  private profileCache: UserProfile = ContextStore.defaultProfile();
  private recordsCache: ServiceRecord[] = [];
  private prompted: Record<string, string> = {};
  private demo: DemoSettings = { simulateStorm: false, simulateDoctorOff: false };

  static getInstance(): ContextStore {
    if (ContextStore.instance === null) {
      ContextStore.instance = new ContextStore();
    }
    return ContextStore.instance;
  }

  isReady(): boolean {
    return this.store !== null;
  }

  async init(ctx: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.loadStore(ctx);
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  private async loadStore(ctx: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(ctx, STORE_NAME);
    } catch (e) {
      console.error(`[ContextStore] open preferences failed: ${e}`);
      this.store = null;
      return;
    }
    this.profileCache = ContextStore.parseProfile(await this.readString(KEY_PROFILE, ''));
    this.recordsCache = ContextStore.parseRecords(await this.readString(KEY_RECORDS, '[]'));
    this.prompted = ContextStore.parseStringMap(await this.readString(KEY_PROMPTED, '{}'));
    this.demo = ContextStore.parseDemo(await this.readString(KEY_DEMO, ''));
  }

  // ==================== 档案 ====================

  static defaultProfile(): UserProfile {
    const p: UserProfile = {
      name: '',
      age: 0,
      homeAddress: '',
      preferredHospitals: [],
      chronicTags: [],
      accessibilityMode: true,
      emergencyContact: ''
    };
    return p;
  }

  /** 返回副本，页面编辑时不会意外改到缓存 */
  getProfile(): UserProfile {
    const p: UserProfile = this.profileCache;
    const copy: UserProfile = {
      name: p.name,
      age: p.age,
      homeAddress: p.homeAddress,
      preferredHospitals: p.preferredHospitals.slice(),
      chronicTags: p.chronicTags.slice(),
      accessibilityMode: p.accessibilityMode,
      emergencyContact: p.emergencyContact
    };
    return copy;
  }

  async saveProfile(p: UserProfile): Promise<void> {
    this.profileCache = p;
    await this.writeString(KEY_PROFILE, JSON.stringify(p));
  }

  // ==================== 病历记录 ====================

  /** 按就诊日期倒序返回副本 */
  getRecords(): ServiceRecord[] {
    const list: ServiceRecord[] = this.recordsCache.slice();
    list.sort((a: ServiceRecord, b: ServiceRecord) => {
      return a.visitDate < b.visitDate ? 1 : (a.visitDate > b.visitDate ? -1 : 0);
    });
    return list;
  }

  /** 追加或覆盖（同 recordId）一条服务记录，供下次复诊规划参考 */
  async addRecord(r: ServiceRecord): Promise<void> {
    const out: ServiceRecord[] = [];
    for (let i = 0; i < this.recordsCache.length; i++) {
      if (this.recordsCache[i].recordId !== r.recordId) {
        out.push(this.recordsCache[i]);
      }
    }
    out.push(r);
    this.recordsCache = out.length > 50 ? out.slice(out.length - 50) : out;
    await this.persistRecords();
  }

  async removeRecord(recordId: string): Promise<void> {
    const out: ServiceRecord[] = [];
    for (let i = 0; i < this.recordsCache.length; i++) {
      if (this.recordsCache[i].recordId !== recordId) {
        out.push(this.recordsCache[i]);
      }
    }
    this.recordsCache = out;
    await this.persistRecords();
  }

  /** 用户在确认卡片上点了“确认无误”后调用 */
  async confirmRecord(recordId: string): Promise<void> {
    for (let i = 0; i < this.recordsCache.length; i++) {
      if (this.recordsCache[i].recordId === recordId) {
        this.recordsCache[i].confirmed = true;
        break;
      }
    }
    await this.persistRecords();
  }

  getPendingRecords(): ServiceRecord[] {
    const pending: ServiceRecord[] = [];
    for (let i = 0; i < this.recordsCache.length; i++) {
      if (!this.recordsCache[i].confirmed) {
        pending.push(this.recordsCache[i]);
      }
    }
    return pending;
  }

  /** 医院名模糊匹配：“第一人民医院”与“市第一人民医院”视为同一家 */
  static sameHospital(a: string, b: string): boolean {
    if (a.length === 0 || b.length === 0) {
      return false;
    }
    return a.indexOf(b) >= 0 || b.indexOf(a) >= 0;
  }

  /**
   * 查找最近一次在指定医院/科室的就诊记录（只信任用户确认过的记录）。
   * 中枢用它判断“这次是不是复诊”，并补全医院、科室与上次处方。
   */
  findLastVisit(hospital: string, department: string): ServiceRecord | null {
    let latest: ServiceRecord | null = null;
    for (let i = 0; i < this.recordsCache.length; i++) {
      const r: ServiceRecord = this.recordsCache[i];
      if (!r.confirmed) {
        continue;
      }
      const hospitalMatch: boolean = hospital.length === 0 || ContextStore.sameHospital(r.hospital, hospital);
      const deptMatch: boolean = department.length === 0 || r.department === department;
      if (hospitalMatch && deptMatch) {
        if (latest === null || r.visitDate > latest.visitDate) {
          latest = r;
        }
      }
    }
    return latest;
  }

  /**
   * 主动服务的核心：扫描到期需要复诊的记录。
   * 同一医院+科室只看最近一条（之后又去过就不再提醒旧的），
   * 用户点“不用了”后不再打扰；语音每天最多播报一次（见 wasPromptedToday）。
   */
  findDueFollowUps(nowTs: number): FollowUpPrompt[] {
    const latestByKey: Map<string, ServiceRecord> = new Map<string, ServiceRecord>();
    for (let i = 0; i < this.recordsCache.length; i++) {
      const r: ServiceRecord = this.recordsCache[i];
      if (!r.confirmed || !DateUtil.isValidYmd(r.visitDate)) {
        continue;
      }
      const key: string = `${r.hospital}|${r.department}`;
      const prev: ServiceRecord | undefined = latestByKey.get(key);
      if (prev === undefined || r.visitDate > prev.visitDate) {
        latestByKey.set(key, r);
      }
    }

    const today: string = DateUtil.todayStr(nowTs);
    const due: FollowUpPrompt[] = [];
    latestByKey.forEach((r: ServiceRecord) => {
      if (r.followUpDays <= 0) {
        return;
      }
      if (this.prompted[r.recordId] === DISMISSED) {
        return;
      }
      const dueDate: string = DateUtil.addDays(r.visitDate, r.followUpDays);
      const daysLeft: number = DateUtil.diffDays(today, dueDate);
      if (daysLeft > FOLLOW_UP_ADVANCE_DAYS || daysLeft < -FOLLOW_UP_OVERDUE_DAYS) {
        return;
      }
      let when: string = '';
      if (daysLeft > 0) {
        const due: Date | null = DateUtil.parseYmd(dueDate);
        const dueText: string = due !== null ? `${due.getMonth() + 1}月${due.getDate()}日` : dueDate;
        when = `还有${daysLeft}天就到复诊时间了（${dueText}）`;
      } else if (daysLeft === 0) {
        when = '今天就到复诊时间了';
      } else {
        when = `复诊时间已经过了${-daysLeft}天`;
      }
      const doctor: string = r.doctorName.length > 0 ? r.doctorName.split(' ')[0] : '医生';
      const prompt: FollowUpPrompt = {
        recordId: r.recordId,
        hospital: r.hospital,
        department: r.department,
        doctorName: r.doctorName,
        dueDate: dueDate,
        text: `上次在${r.hospital}${r.department}看的病，${when}。要我帮您约${doctor}的复诊吗？`
      };
      due.push(prompt);
    });
    return due;
  }

  /** 今天是否已经语音询问过这条复诊（卡片可以一直显示，但语音每天只播一次） */
  wasPromptedToday(recordId: string, nowTs: number): boolean {
    return this.prompted[recordId] === DateUtil.todayStr(nowTs);
  }

  /** 记录今天已经询问过，避免每次回到前台都重复播报 */
  async markFollowUpPrompted(recordId: string, nowTs: number): Promise<void> {
    this.prompted[recordId] = DateUtil.todayStr(nowTs);
    await this.writeString(KEY_PROMPTED, JSON.stringify(this.prompted));
  }

  /** 用户明确表示不需要，这条记录不再主动提醒 */
  async dismissFollowUp(recordId: string): Promise<void> {
    this.prompted[recordId] = DISMISSED;
    await this.writeString(KEY_PROMPTED, JSON.stringify(this.prompted));
  }

  // ==================== 演示开关与演示数据 ====================

  getDemoSettings(): DemoSettings {
    const d: DemoSettings = {
      simulateStorm: this.demo.simulateStorm,
      simulateDoctorOff: this.demo.simulateDoctorOff
    };
    return d;
  }

  async saveDemoSettings(d: DemoSettings): Promise<void> {
    this.demo = d;
    await this.writeString(KEY_DEMO, JSON.stringify(d));
  }

  /** 首次运行（或旧版演示数据）时写入演示档案和一条“快到复诊时间”的历史记录 */
  async ensureDemoSeed(nowTs: number): Promise<void> {
    if (this.store === null) {
      return;
    }
    let version: number = 0;
    try {
      version = await this.store.get(KEY_SEED, 0) as number;
    } catch (e) {
      version = 0;
    }
    if (version >= SEED_VERSION) {
      return;
    }
    if (this.profileCache.name.length === 0) {
      await this.saveProfile(ContextStore.demoProfile());
    }
    const existing: ServiceRecord | null = this.findRecord(DEMO_RECORD_ID);
    if (existing === null || existing.source === RecordSource.MANUAL_INPUT) {
      await this.addRecord(ContextStore.demoRecord(nowTs));
    }
    await this.writeNumber(KEY_SEED, SEED_VERSION);
  }

  /** “我的”页面：恢复演示数据（答辩前一键复位） */
  async resetDemoData(nowTs: number): Promise<void> {
    this.recordsCache = [];
    this.prompted = {};
    await this.persistRecords();
    await this.writeString(KEY_PROMPTED, '{}');
    await this.saveProfile(ContextStore.demoProfile());
    await this.addRecord(ContextStore.demoRecord(nowTs));
    await this.saveDemoSettings({ simulateStorm: false, simulateDoctorOff: false });
    await this.writeNumber(KEY_SEED, SEED_VERSION);
  }

  /** 清除全部端侧数据（隐私承诺：用户可随时删除） */
  async clearAll(): Promise<void> {
    this.profileCache = ContextStore.defaultProfile();
    this.recordsCache = [];
    this.prompted = {};
    this.demo = { simulateStorm: false, simulateDoctorOff: false };
    if (this.store === null) {
      return;
    }
    try {
      await this.store.clear();
      await this.store.put(KEY_SEED, SEED_VERSION);
      await this.store.flush();
    } catch (e) {
      console.error(`[ContextStore] clear failed: ${e}`);
    }
  }

  private static demoProfile(): UserProfile {
    const p: UserProfile = {
      name: '张秀兰',
      age: 72,
      homeAddress: '幸福小区3栋2单元',
      preferredHospitals: ['市第一人民医院'],
      chronicTags: ['高血压'],
      accessibilityMode: true,
      emergencyContact: '13800000000'
    };
    return p;
  }

  private static demoRecord(nowTs: number): ServiceRecord {
    // 27 天前就诊、医嘱 30 天复诊 → 3 天后到期，打开 App 即可看到主动复诊提醒
    const r: ServiceRecord = {
      recordId: DEMO_RECORD_ID,
      hospital: '市第一人民医院',
      department: '心血管内科',
      doctorName: '王建国 主任医师',
      visitDate: DateUtil.dateAfter(nowTs, -27),
      followUpDays: 30,
      prescription: '苯磺酸氨氯地平片 每日1次 每次5mg',
      source: RecordSource.MANUAL_INPUT,
      confirmed: true
    };
    return r;
  }

  private findRecord(recordId: string): ServiceRecord | null {
    for (let i = 0; i < this.recordsCache.length; i++) {
      if (this.recordsCache[i].recordId === recordId) {
        return this.recordsCache[i];
      }
    }
    return null;
  }

  // ==================== 给大模型的上下文 ====================

  /** 构建给大模型的上下文摘要：不含姓名、精确住址、医生姓名，控制长度 */
  buildContextSummary(rt: RuntimeContext): string {
    const p: UserProfile = this.profileCache;
    const parts: string[] = [];
    if (p.age > 0) {
      const ageBand: number = Math.floor(p.age / 10) * 10;
      parts.push(`用户年龄段：${ageBand}多岁`);
    }
    if (p.chronicTags.length > 0) {
      parts.push(`慢病：${p.chronicTags.join('、')}`);
    }
    if (p.preferredHospitals.length > 0) {
      parts.push(`常去医院：${p.preferredHospitals.join('、')}`);
    }
    if (rt.cityName.length > 0) {
      parts.push(`所在城市：${rt.cityName}`);
    }
    parts.push(`天气：${rt.weather}`);

    const recent: ServiceRecord[] = this.getRecords().slice(0, 3);
    if (recent.length > 0) {
      const list: string[] = [];
      for (let i = 0; i < recent.length; i++) {
        list.push(`${recent[i].visitDate} ${recent[i].hospital}${recent[i].department}`);
      }
      parts.push(`近期就诊：${list.join('；')}`);
    }
    return parts.join('。');
  }

  // ==================== 持久化与解析 ====================

  private async persistRecords(): Promise<void> {
    await this.writeString(KEY_RECORDS, JSON.stringify(this.recordsCache));
  }

  private async readString(key: string, def: string): Promise<string> {
    if (this.store === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = await this.store.get(key, def);
      return typeof v === 'string' ? v : def;
    } catch (e) {
      console.error(`[ContextStore] read ${key} failed: ${e}`);
      return def;
    }
  }

  private async writeString(key: string, value: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (e) {
      console.error(`[ContextStore] write ${key} failed: ${e}`);
    }
  }

  private async writeNumber(key: string, value: number): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (e) {
      console.error(`[ContextStore] write ${key} failed: ${e}`);
    }
  }

  private static parseObject(raw: string): Record<string, Object> | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const v: Object = JSON.parse(raw) as Object;
      if (v === null || typeof v !== 'object' || Array.isArray(v)) {
        return null;
      }
      return v as Record<string, Object>;
    } catch (e) {
      console.error(`[ContextStore] corrupted json, ignore: ${e}`);
      return null;
    }
  }

  private static str(obj: Record<string, Object>, key: string, def: string): string {
    const v: Object | undefined = obj[key];
    return typeof v === 'string' ? v : def;
  }

  private static num(obj: Record<string, Object>, key: string, def: number): number {
    const v: Object | undefined = obj[key];
    if (typeof v === 'number' && isFinite(v)) {
      return v;
    }
    if (typeof v === 'string') {
      const n: number = Number(v);
      return isFinite(n) ? n : def;
    }
    return def;
  }

  private static bool(obj: Record<string, Object>, key: string, def: boolean): boolean {
    const v: Object | undefined = obj[key];
    return typeof v === 'boolean' ? v : def;
  }

  private static strList(obj: Record<string, Object>, key: string): string[] {
    const v: Object | undefined = obj[key];
    const out: string[] = [];
    if (Array.isArray(v)) {
      const arr: Object[] = v as Object[];
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          out.push(arr[i] as string);
        }
      }
    }
    return out;
  }

  private static parseProfile(raw: string): UserProfile {
    const obj: Record<string, Object> | null = ContextStore.parseObject(raw);
    if (obj === null) {
      return ContextStore.defaultProfile();
    }
    const p: UserProfile = {
      name: ContextStore.str(obj, 'name', ''),
      age: ContextStore.num(obj, 'age', 0),
      homeAddress: ContextStore.str(obj, 'homeAddress', ''),
      preferredHospitals: ContextStore.strList(obj, 'preferredHospitals'),
      chronicTags: ContextStore.strList(obj, 'chronicTags'),
      accessibilityMode: ContextStore.bool(obj, 'accessibilityMode', true),
      emergencyContact: ContextStore.str(obj, 'emergencyContact', '')
    };
    return p;
  }

  private static toSource(s: string): RecordSource {
    if (s === 'USER_SPOKEN') {
      return RecordSource.USER_SPOKEN;
    }
    if (s === 'OCR_SCAN') {
      return RecordSource.OCR_SCAN;
    }
    if (s === 'POST_VISIT_ASK') {
      return RecordSource.POST_VISIT_ASK;
    }
    return RecordSource.MANUAL_INPUT;
  }

  private static parseRecords(raw: string): ServiceRecord[] {
    const out: ServiceRecord[] = [];
    try {
      const v: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(v)) {
        return out;
      }
      const arr: Object[] = v as Object[];
      for (let i = 0; i < arr.length; i++) {
        const item: Object = arr[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const obj: Record<string, Object> = item as Record<string, Object>;
        const recordId: string = ContextStore.str(obj, 'recordId', '');
        if (recordId.length === 0) {
          continue;
        }
        const r: ServiceRecord = {
          recordId: recordId,
          hospital: ContextStore.str(obj, 'hospital', ''),
          department: ContextStore.str(obj, 'department', ''),
          doctorName: ContextStore.str(obj, 'doctorName', ''),
          visitDate: ContextStore.str(obj, 'visitDate', ''),
          followUpDays: Math.max(0, Math.round(ContextStore.num(obj, 'followUpDays', 0))),
          prescription: ContextStore.str(obj, 'prescription', ''),
          source: ContextStore.toSource(ContextStore.str(obj, 'source', '')),
          confirmed: ContextStore.bool(obj, 'confirmed', false)
        };
        out.push(r);
      }
    } catch (e) {
      console.error(`[ContextStore] corrupted records, reset: ${e}`);
    }
    return out;
  }

  private static parseStringMap(raw: string): Record<string, string> {
    const out: Record<string, string> = {};
    const obj: Record<string, Object> | null = ContextStore.parseObject(raw);
    if (obj === null) {
      return out;
    }
    const keys: string[] = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      const v: Object | undefined = obj[keys[i]];
      if (typeof v === 'string') {
        out[keys[i]] = v;
      }
    }
    return out;
  }

  private static parseDemo(raw: string): DemoSettings {
    const obj: Record<string, Object> | null = ContextStore.parseObject(raw);
    if (obj === null) {
      return { simulateStorm: false, simulateDoctorOff: false };
    }
    const d: DemoSettings = {
      simulateStorm: ContextStore.bool(obj, 'simulateStorm', false),
      simulateDoctorOff: ContextStore.bool(obj, 'simulateDoctorOff', false)
    };
    return d;
  }
}
