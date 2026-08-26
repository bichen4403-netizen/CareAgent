import preferences from "@ohos:data.preferences";
import type common from "@ohos:app.ability.common";
import formProvider from "@ohos:app.form.formProvider";
import formBindingData from "@ohos:app.form.formBindingData";
const CARD_STORE: string = 'zht_card';
const KEY_SNAPSHOT: string = 'snapshot';
const KEY_FORM_IDS: string = 'form_ids';
/** 卡片展示的数据快照 —— 只放卡片真正要显示的字段，保持轻量 */
export interface CardSnapshot {
    /** 是否有进行中的陪诊安排 */
    hasPlan: boolean;
    /** 主标题，如 "明天 09:00 心血管内科" */
    title: string;
    /** 下一步动作，如 "07:52 出发" */
    nextAction: string;
    /** 补充说明，如 "今天有雨，已多留25分钟" */
    detail: string;
    /** 医院名 */
    hospital: string;
    /** 当前处于第几步 / 共几步 */
    stepIndex: number;
    stepTotal: number;
    updatedAt: number;
}
export class CardDataStore {
    private static emptySnapshot(): CardSnapshot {
        return {
            hasPlan: false,
            title: '还没有陪诊安排',
            nextAction: '点一下，说句话就能安排',
            detail: '',
            hospital: '',
            stepIndex: 0,
            stepTotal: 0,
            updatedAt: Date.now()
        };
    }
    // ==================== 写入（主应用侧调用） ====================
    /**
     * 方案确认或状态变化时写入快照，并立即推送刷新所有已添加的卡片
     */
    static async writeSnapshot(ctx: common.Context, snapshot: CardSnapshot): Promise<void> {
        const store: preferences.Preferences = await preferences.getPreferences(ctx, CARD_STORE);
        await store.put(KEY_SNAPSHOT, JSON.stringify(snapshot));
        await store.flush();
        await CardDataStore.pushRefresh(ctx, snapshot);
    }
    /** 主动刷新桌面上所有该应用的卡片 */
    private static async pushRefresh(ctx: common.Context, snapshot: CardSnapshot): Promise<void> {
        const ids: string[] = await CardDataStore.readFormIds(ctx);
        if (ids.length === 0) {
            return;
        }
        const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(CardDataStore.toBindingObject(snapshot));
        for (let i = 0; i < ids.length; i++) {
            try {
                await formProvider.updateForm(ids[i], data);
            }
            catch (e) {
                console.error(`[CardDataStore] refresh ${ids[i]} failed: ${e}`);
            }
        }
        console.info(`[CardDataStore] pushed refresh to ${ids.length} cards`);
    }
    // ==================== 读取（卡片侧调用） ====================
    /** 卡片刷新回调里同步读取，读不到则返回空态 */
    static readSync(ctx: common.Context): CardSnapshot {
        try {
            const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: CARD_STORE });
            const raw: string = store.getSync(KEY_SNAPSHOT, '') as string;
            if (raw.length === 0) {
                return CardDataStore.emptySnapshot();
            }
            return JSON.parse(raw) as CardSnapshot;
        }
        catch (e) {
            console.error(`[CardDataStore] readSync failed: ${e}`);
            return CardDataStore.emptySnapshot();
        }
    }
    /** 转成卡片绑定数据 —— 字段名要与 CareCard.ets 中的 @LocalStorageProp 对应 */
    static toBindingObject(s: CardSnapshot): Record<string, Object> {
        return {
            'hasPlan': s.hasPlan,
            'title': s.title,
            'nextAction': s.nextAction,
            'detail': s.detail,
            'hospital': s.hospital,
            'stepIndex': s.stepIndex,
            'stepTotal': s.stepTotal
        };
    }
    // ==================== formId 管理 ====================
    static rememberFormId(ctx: common.Context, formId: string): void {
        if (formId.length === 0) {
            return;
        }
        try {
            const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: CARD_STORE });
            const raw: string = store.getSync(KEY_FORM_IDS, '[]') as string;
            const ids: string[] = JSON.parse(raw) as string[];
            if (ids.indexOf(formId) < 0) {
                ids.push(formId);
                store.putSync(KEY_FORM_IDS, JSON.stringify(ids));
                store.flush();
            }
        }
        catch (e) {
            console.error(`[CardDataStore] rememberFormId failed: ${e}`);
        }
    }
    static forgetFormId(ctx: common.Context, formId: string): void {
        try {
            const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: CARD_STORE });
            const raw: string = store.getSync(KEY_FORM_IDS, '[]') as string;
            const ids: string[] = JSON.parse(raw) as string[];
            const out: string[] = [];
            for (let i = 0; i < ids.length; i++) {
                if (ids[i] !== formId) {
                    out.push(ids[i]);
                }
            }
            store.putSync(KEY_FORM_IDS, JSON.stringify(out));
            store.flush();
        }
        catch (e) {
            console.error(`[CardDataStore] forgetFormId failed: ${e}`);
        }
    }
    private static async readFormIds(ctx: common.Context): Promise<string[]> {
        try {
            const store: preferences.Preferences = await preferences.getPreferences(ctx, CARD_STORE);
            const raw: string = await store.get(KEY_FORM_IDS, '[]') as string;
            return JSON.parse(raw) as string[];
        }
        catch (e) {
            return [];
        }
    }
}
