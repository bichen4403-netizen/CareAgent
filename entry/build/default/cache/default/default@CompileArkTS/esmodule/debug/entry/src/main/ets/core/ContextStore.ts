import preferences from "@ohos:data.preferences";
import type common from "@ohos:app.ability.common";
import type { UserProfile, ServiceRecord, RuntimeContext } from './AgentTypes';
const STORE_NAME: string = 'zht_context';
const KEY_PROFILE: string = 'user_profile';
const KEY_RECORDS: string = 'service_records';
export class ContextStore {
    private static instance: ContextStore | null = null;
    private store: preferences.Preferences | null = null;
    private profileCache: UserProfile | null = null;
    private recordsCache: ServiceRecord[] = [];
    static getInstance(): ContextStore {
        if (ContextStore.instance === null) {
            ContextStore.instance = new ContextStore();
        }
        return ContextStore.instance;
    }
    async init(ctx: common.UIAbilityContext): Promise<void> {
        this.store = await preferences.getPreferences(ctx, STORE_NAME);
        await this.loadAll();
    }
    private async loadAll(): Promise<void> {
        if (this.store === null) {
            return;
        }
        const profileStr: string = await this.store.get(KEY_PROFILE, '') as string;
        if (profileStr.length > 0) {
            this.profileCache = JSON.parse(profileStr) as UserProfile;
        }
        else {
            this.profileCache = ContextStore.defaultProfile();
        }
        const recordStr: string = await this.store.get(KEY_RECORDS, '[]') as string;
        this.recordsCache = JSON.parse(recordStr) as ServiceRecord[];
    }
    private static defaultProfile(): UserProfile {
        return {
            name: '',
            age: 0,
            homeAddress: '',
            preferredHospitals: [],
            chronicTags: [],
            accessibilityMode: true,
            emergencyContact: ''
        };
    }
    getProfile(): UserProfile {
        if (this.profileCache === null) {
            return ContextStore.defaultProfile();
        }
        return this.profileCache;
    }
    async saveProfile(p: UserProfile): Promise<void> {
        this.profileCache = p;
        if (this.store === null) {
            return;
        }
        await this.store.put(KEY_PROFILE, JSON.stringify(p));
        await this.store.flush();
    }
    getRecords(): ServiceRecord[] {
        return this.recordsCache;
    }
    /** 追加一条服务记录，供下次复诊规划参考 */
    async addRecord(r: ServiceRecord): Promise<void> {
        this.recordsCache.push(r);
        if (this.recordsCache.length > 50) {
            this.recordsCache = this.recordsCache.slice(this.recordsCache.length - 50);
        }
        if (this.store === null) {
            return;
        }
        await this.store.put(KEY_RECORDS, JSON.stringify(this.recordsCache));
        await this.store.flush();
    }
    /**
     * 查找最近一次在指定医院/科室的就诊记录
     * 中枢 Agent 用它判断"这次是不是复诊"，从而跳过重复的问诊准备步骤
     *
     * 安全原则：只信任 confirmed=true 的记录。
     * 口述或识别但未经用户确认的记录不参与自动补全，避免把没核实过的信息当医嘱用。
     */
    findLastVisit(hospital: string, department: string): ServiceRecord | null {
        let latest: ServiceRecord | null = null;
        for (let i = 0; i < this.recordsCache.length; i++) {
            const r: ServiceRecord = this.recordsCache[i];
            if (!r.confirmed) {
                continue;
            }
            const hospitalMatch: boolean = hospital.length === 0 || r.hospital.indexOf(hospital) >= 0;
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
     * 主动服务的核心：扫描到期需要复诊的记录
     * 由后台任务定时调用，命中则主动发起一次陪诊规划并推送给用户
     * 同样只扫描已确认记录，避免拿不可靠信息主动打扰用户
     */
    findDueFollowUps(nowTs: number): ServiceRecord[] {
        const due: ServiceRecord[] = [];
        for (let i = 0; i < this.recordsCache.length; i++) {
            const r: ServiceRecord = this.recordsCache[i];
            if (!r.confirmed || r.followUpDays <= 0) {
                continue;
            }
            const visitTs: number = new Date(r.visitDate).getTime();
            const dueTs: number = visitTs + r.followUpDays * 24 * 3600 * 1000;
            const advanceTs: number = dueTs - 3 * 24 * 3600 * 1000; // 提前3天进入提醒窗口
            if (nowTs >= advanceTs && nowTs <= dueTs) {
                due.push(r);
            }
        }
        return due;
    }
    /** 待确认记录：拍照识别/口述采集到但用户还没点确认的，需要在 UI 上提醒用户核对 */
    getPendingRecords(): ServiceRecord[] {
        const pending: ServiceRecord[] = [];
        for (let i = 0; i < this.recordsCache.length; i++) {
            if (!this.recordsCache[i].confirmed) {
                pending.push(this.recordsCache[i]);
            }
        }
        return pending;
    }
    /** 用户在确认卡片上点了"确认无误"后调用 */
    async confirmRecord(recordId: string): Promise<void> {
        for (let i = 0; i < this.recordsCache.length; i++) {
            if (this.recordsCache[i].recordId === recordId) {
                this.recordsCache[i].confirmed = true;
                break;
            }
        }
        if (this.store === null) {
            return;
        }
        await this.store.put(KEY_RECORDS, JSON.stringify(this.recordsCache));
        await this.store.flush();
    }
    /** 构建给大模型的上下文摘要，控制长度避免 token 浪费 */
    buildContextSummary(rt: RuntimeContext): string {
        const p: UserProfile = this.getProfile();
        const parts: string[] = [];
        if (p.name.length > 0) {
            parts.push(`用户${p.name}，${p.age}岁`);
        }
        if (p.chronicTags.length > 0) {
            parts.push(`慢病：${p.chronicTags.join('、')}`);
        }
        if (p.homeAddress.length > 0) {
            parts.push(`住址：${p.homeAddress}`);
        }
        if (p.preferredHospitals.length > 0) {
            parts.push(`常去医院：${p.preferredHospitals.join('、')}`);
        }
        if (rt.currentAddress.length > 0) {
            parts.push(`当前位置：${rt.currentAddress}`);
        }
        parts.push(`天气：${rt.weather}，路况：${rt.trafficLevel}`);
        const recent: ServiceRecord[] = this.recordsCache.slice(-3);
        if (recent.length > 0) {
            const list: string[] = [];
            for (let i = 0; i < recent.length; i++) {
                const r: ServiceRecord = recent[i];
                list.push(`${r.visitDate} ${r.hospital}${r.department}(${r.doctorName})`);
            }
            parts.push(`近期就诊：${list.join('；')}`);
        }
        return parts.join('。');
    }
}
