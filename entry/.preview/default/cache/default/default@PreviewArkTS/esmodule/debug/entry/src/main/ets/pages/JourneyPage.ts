if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface JourneyPage_Params {
    appt?: Appointment | null;
    travel?: TravelPlan | null;
    nav?: IndoorNavPlan | null;
    reminders?: ReminderItem[];
    confirmed?: boolean;
}
import router from "@ohos:router";
import type common from "@ohos:app.ability.common";
import { BookingStatus } from "@bundle:com.example.zhihutongxing/entry/ets/core/AgentTypes";
import type { Appointment, TravelPlan, IndoorNavPlan, NavStep, ReminderItem, AgentResult } from "@bundle:com.example.zhihutongxing/entry/ets/core/AgentTypes";
import { blackboard } from "@bundle:com.example.zhihutongxing/entry/ets/core/EventBus";
import { DeviceSyncService } from "@bundle:com.example.zhihutongxing/entry/ets/services/DeviceSyncService";
import { CardDataStore } from "@bundle:com.example.zhihutongxing/entry/ets/widget/CardDataStore";
import type { CardSnapshot } from "@bundle:com.example.zhihutongxing/entry/ets/widget/CardDataStore";
import { OfficialChannelRegistry, AppLinkService } from "@bundle:com.example.zhihutongxing/entry/ets/services/AppLinkService";
import type { OfficialChannel } from "@bundle:com.example.zhihutongxing/entry/ets/services/AppLinkService";
class JourneyPage extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__appt = new ObservedPropertyObjectPU(null, this, "appt");
        this.__travel = new ObservedPropertyObjectPU(null, this, "travel");
        this.__nav = new ObservedPropertyObjectPU(null, this, "nav");
        this.__reminders = new ObservedPropertyObjectPU([], this, "reminders");
        this.__confirmed = new ObservedPropertySimplePU(false, this, "confirmed");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: JourneyPage_Params) {
        if (params.appt !== undefined) {
            this.appt = params.appt;
        }
        if (params.travel !== undefined) {
            this.travel = params.travel;
        }
        if (params.nav !== undefined) {
            this.nav = params.nav;
        }
        if (params.reminders !== undefined) {
            this.reminders = params.reminders;
        }
        if (params.confirmed !== undefined) {
            this.confirmed = params.confirmed;
        }
    }
    updateStateVars(params: JourneyPage_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__appt.purgeDependencyOnElmtId(rmElmtId);
        this.__travel.purgeDependencyOnElmtId(rmElmtId);
        this.__nav.purgeDependencyOnElmtId(rmElmtId);
        this.__reminders.purgeDependencyOnElmtId(rmElmtId);
        this.__confirmed.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__appt.aboutToBeDeleted();
        this.__travel.aboutToBeDeleted();
        this.__nav.aboutToBeDeleted();
        this.__reminders.aboutToBeDeleted();
        this.__confirmed.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __appt: ObservedPropertyObjectPU<Appointment | null>;
    get appt() {
        return this.__appt.get();
    }
    set appt(newValue: Appointment | null) {
        this.__appt.set(newValue);
    }
    private __travel: ObservedPropertyObjectPU<TravelPlan | null>;
    get travel() {
        return this.__travel.get();
    }
    set travel(newValue: TravelPlan | null) {
        this.__travel.set(newValue);
    }
    private __nav: ObservedPropertyObjectPU<IndoorNavPlan | null>;
    get nav() {
        return this.__nav.get();
    }
    set nav(newValue: IndoorNavPlan | null) {
        this.__nav.set(newValue);
    }
    private __reminders: ObservedPropertyObjectPU<ReminderItem[]>;
    get reminders() {
        return this.__reminders.get();
    }
    set reminders(newValue: ReminderItem[]) {
        this.__reminders.set(newValue);
    }
    private __confirmed: ObservedPropertySimplePU<boolean>;
    get confirmed() {
        return this.__confirmed.get();
    }
    set confirmed(newValue: boolean) {
        this.__confirmed.set(newValue);
    }
    aboutToAppear(): void {
        this.loadFromBlackboard();
    }
    /** 从共享黑板取出各 Agent 的产出 */
    private loadFromBlackboard(): void {
        const medical: AgentResult | undefined = blackboard.getResultByAgent('MedicalAgent');
        if (medical !== undefined && medical.data.length > 0) {
            const d: Record<string, Object> = JSON.parse(medical.data) as Record<string, Object>;
            this.appt = d['appointment'] as Appointment;
        }
        const travelRes: AgentResult | undefined = blackboard.getResultByAgent('TravelAgent');
        if (travelRes !== undefined && travelRes.data.length > 0) {
            const d: Record<string, Object> = JSON.parse(travelRes.data) as Record<string, Object>;
            this.travel = d['travelPlan'] as TravelPlan;
        }
        const navRes: AgentResult | undefined = blackboard.getResultByAgent('NavigationAgent');
        if (navRes !== undefined && navRes.data.length > 0) {
            const d: Record<string, Object> = JSON.parse(navRes.data) as Record<string, Object>;
            this.nav = d['navPlan'] as IndoorNavPlan;
        }
        const remindRes: AgentResult | undefined = blackboard.getResultByAgent('ReminderAgent');
        if (remindRes !== undefined && remindRes.data.length > 0) {
            const d: Record<string, Object> = JSON.parse(remindRes.data) as Record<string, Object>;
            this.reminders = d['reminders'] as ReminderItem[];
        }
    }
    /**
     * 第一步：跳转官方渠道
     * 只是把用户带过去，不代表挂号已完成，所以这里不设置 confirmed
     */
    private async onGoToOfficialChannel(): Promise<void> {
        if (this.appt === null) {
            return;
        }
        const channel: OfficialChannel = OfficialChannelRegistry.resolve(this.appt.hospitalAddress);
        this.appt.bookingStatus = BookingStatus.AWAITING_OFFICIAL;
        const ctx = getContext(this) as common.UIAbilityContext;
        const opened: boolean = await AppLinkService.openOfficialChannel(ctx, channel);
        if (opened) {
            DeviceSyncService.speak(`已经帮您打开${channel.name}，${channel.hint}`);
        }
        else {
            DeviceSyncService.speak(`没能自动打开${channel.name}，麻烦您手动打开一下官方渠道确认`);
        }
    }
    /**
     * 第二步：用户从官方渠道回来后，手动确认"我真的挂上号了"
     * 只有这一步之后才真正注册出行提醒、同步桌面卡片 —— 避免用户还没挂上号，
     * 手表却已经在提醒"该出发了"这种前后矛盾的体验
     */
    private onConfirmOfficialDone(): void {
        if (this.appt === null) {
            return;
        }
        this.appt.bookingStatus = BookingStatus.CONFIRMED;
        this.confirmed = true;
        DeviceSyncService.scheduleReminders(this.reminders);
        DeviceSyncService.speak('好的，都记下了，到时间我会提醒您');
        this.syncToCard();
    }
    /**
     * 把方案同步到桌面卡片
     * 老人不用打开 App，在桌面就能看到"下一步该做什么"
     */
    private syncToCard(): void {
        if (this.appt === null) {
            return;
        }
        const ctx = getContext(this) as common.UIAbilityContext;
        const departTime: string = this.travel === null ? this.appt.visitTime : this.travel.departTime;
        const detail: string = this.travel === null ? '' : this.travel.suggestion;
        const snapshot: CardSnapshot = {
            hasPlan: true,
            title: `${this.appt.visitDate} ${this.appt.visitTime} ${this.appt.department}`,
            nextAction: `${departTime} 出发`,
            detail: detail,
            hospital: this.appt.hospitalName,
            stepIndex: 1,
            stepTotal: this.reminders.length,
            updatedAt: Date.now()
        };
        CardDataStore.writeSnapshot(ctx, snapshot).catch((e: Error) => {
            console.error(`[JourneyPage] sync card failed: ${e.message}`);
        });
    }
    private bookingStatusLabel(s: BookingStatus): string {
        if (s === BookingStatus.CONFIRMED) {
            return '已在官方渠道确认';
        }
        if (s === BookingStatus.AWAITING_OFFICIAL) {
            return '已跳转官方渠道，等待确认';
        }
        return 'AI推荐方案，待官方确认';
    }
    private deviceLabel(d: string): string {
        if (d === 'watch') {
            return '手表';
        }
        if (d === 'earphone') {
            return '耳机';
        }
        return '手机';
    }
    private formatTime(ts: number): string {
        const d: Date = new Date(ts);
        const h: string = `${d.getHours()}`.padStart(2, '0');
        const m: string = `${d.getMinutes()}`.padStart(2, '0');
        return `${d.getMonth() + 1}月${d.getDate()}日 ${h}:${m}`;
    }
    SectionCard(title: string, tag: string, parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/JourneyPage.ets(156:5)", "entry");
            Row.width('100%');
            Row.margin({ bottom: 12 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(title);
            Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(157:7)", "entry");
            Text.fontSize(20);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#1B2A34');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/JourneyPage.ets(161:7)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(tag);
            Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(162:7)", "entry");
            Text.fontSize(14);
            Text.fontColor('#2E6F8E');
            Text.padding({ left: 10, right: 10, top: 4, bottom: 4 });
            Text.backgroundColor('#E3EEF4');
            Text.borderRadius(10);
        }, Text);
        Text.pop();
        Row.pop();
    }
    InfoRow(label: string, value: string, parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/JourneyPage.ets(175:5)", "entry");
            Row.width('100%');
            Row.padding({ top: 7, bottom: 7 });
            Row.alignItems(VerticalAlign.Top);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(label);
            Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(176:7)", "entry");
            Text.fontSize(18);
            Text.fontColor('#7A8A96');
            Text.width(88);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(value);
            Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(180:7)", "entry");
            Text.fontSize(18);
            Text.fontColor('#22303C');
            Text.layoutWeight(1);
        }, Text);
        Text.pop();
        Row.pop();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(191:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor('#EEF3F6');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 标题栏
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/JourneyPage.ets(193:7)", "entry");
            // 标题栏
            Row.width('100%');
            // 标题栏
            Row.padding({ left: 20, right: 20, top: 14, bottom: 14 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('返回');
            Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(194:9)", "entry");
            Text.fontSize(18);
            Text.fontColor('#2E6F8E');
            Text.onClick(() => {
                router.back();
            });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/JourneyPage.ets(200:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('陪诊安排');
            Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(201:9)", "entry");
            Text.fontSize(22);
            Text.fontWeight(FontWeight.Bold);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/JourneyPage.ets(204:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('  ');
            Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(205:9)", "entry");
            Text.fontSize(18);
        }, Text);
        Text.pop();
        // 标题栏
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Scroll.create();
            Scroll.debugLine("entry/src/main/ets/pages/JourneyPage.ets(211:7)", "entry");
            Scroll.layoutWeight(1);
            Scroll.scrollBar(BarState.Off);
        }, Scroll);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(212:9)", "entry");
            Column.width('100%');
            Column.padding({ left: 16, right: 16, bottom: 20 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 就诊安排
            if (this.appt !== null) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(215:13)", "entry");
                        __Column__cardStyle();
                    }, Column);
                    this.SectionCard.bind(this)('就诊安排', '医疗 Agent');
                    this.InfoRow.bind(this)('医院', this.appt.hospitalName);
                    this.InfoRow.bind(this)('科室', this.appt.department);
                    this.InfoRow.bind(this)('医生', this.appt.doctorName);
                    this.InfoRow.bind(this)('时间', `${this.appt.visitDate} ${this.appt.visitTime}`);
                    this.InfoRow.bind(this)('诊室', `${this.appt.buildingName}${this.appt.floor}${this.appt.roomNo}`);
                    this.InfoRow.bind(this)('费用', `${this.appt.registrationFee}元`);
                    this.InfoRow.bind(this)('状态', this.bookingStatusLabel(this.appt.bookingStatus));
                    Column.pop();
                });
            }
            // 出行方案
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 出行方案
            if (this.travel !== null) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(230:13)", "entry");
                        __Column__cardStyle();
                    }, Column);
                    this.SectionCard.bind(this)('出行方案', '出行 Agent');
                    this.InfoRow.bind(this)('出发', `${this.travel.departTime}`);
                    this.InfoRow.bind(this)('车程', `约${this.travel.durationMin}分钟 · ${this.travel.distanceKm}公里`);
                    this.InfoRow.bind(this)('路况', `${this.travel.trafficLevel} · ${this.travel.weather}`);
                    this.InfoRow.bind(this)('说明', this.travel.suggestion);
                    Column.pop();
                });
            }
            // 院内路线
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 院内路线
            if (this.nav !== null) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(242:13)", "entry");
                        __Column__cardStyle();
                    }, Column);
                    this.SectionCard.bind(this)('院内路线', '导航 Agent');
                    this.InfoRow.bind(this)('入口', this.nav.entrance);
                    this.InfoRow.bind(this)('目的地', this.nav.targetRoom);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        ForEach.create();
                        const forEachItemGenFunction = _item => {
                            const s = _item;
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Row.create();
                                Row.debugLine("entry/src/main/ets/pages/JourneyPage.ets(247:17)", "entry");
                                Row.width('100%');
                                Row.padding({ top: 8, bottom: 8 });
                                Row.alignItems(VerticalAlign.Top);
                            }, Row);
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create(`${s.order}`);
                                Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(248:19)", "entry");
                                Text.fontSize(15);
                                Text.fontColor('#FFFFFF');
                                Text.width(26);
                                Text.height(26);
                                Text.textAlign(TextAlign.Center);
                                Text.backgroundColor('#7FA8C9');
                                Text.borderRadius(13);
                            }, Text);
                            Text.pop();
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create(s.instruction);
                                Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(256:19)", "entry");
                                Text.fontSize(17);
                                Text.fontColor('#22303C');
                                Text.layoutWeight(1);
                                Text.margin({ left: 12 });
                            }, Text);
                            Text.pop();
                            Row.pop();
                        };
                        this.forEachUpdateFunction(elmtId, this.nav.steps, forEachItemGenFunction, (s: NavStep) => `${s.order}`, false, false);
                    }, ForEach);
                    ForEach.pop();
                    Column.pop();
                });
            }
            // 提醒清单 —— 体现跨设备分工
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 提醒清单 —— 体现跨设备分工
            if (this.reminders.length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(272:13)", "entry");
                        __Column__cardStyle();
                    }, Column);
                    this.SectionCard.bind(this)('全流程提醒', '提醒 Agent');
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        ForEach.create();
                        const forEachItemGenFunction = _item => {
                            const r = _item;
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Row.create();
                                Row.debugLine("entry/src/main/ets/pages/JourneyPage.ets(275:17)", "entry");
                                Row.width('100%');
                                Row.padding({ top: 10, bottom: 10 });
                                Row.alignItems(VerticalAlign.Top);
                            }, Row);
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Column.create();
                                Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(276:19)", "entry");
                                Column.layoutWeight(1);
                                Column.alignItems(HorizontalAlign.Start);
                            }, Column);
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create(r.title);
                                Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(277:21)", "entry");
                                Text.fontSize(18);
                                Text.fontColor('#22303C');
                                Text.width('100%');
                            }, Text);
                            Text.pop();
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create(r.content);
                                Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(281:21)", "entry");
                                Text.fontSize(15);
                                Text.fontColor('#7A8A96');
                                Text.width('100%');
                                Text.margin({ top: 3 });
                            }, Text);
                            Text.pop();
                            Column.pop();
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Column.create();
                                Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(290:19)", "entry");
                                Column.alignItems(HorizontalAlign.End);
                            }, Column);
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create(this.deviceLabel(r.targetDevice));
                                Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(291:21)", "entry");
                                Text.fontSize(14);
                                Text.fontColor('#B5622C');
                                Text.padding({ left: 8, right: 8, top: 3, bottom: 3 });
                                Text.backgroundColor('#F7E9DC');
                                Text.borderRadius(8);
                            }, Text);
                            Text.pop();
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create(this.formatTime(r.triggerAt));
                                Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(297:21)", "entry");
                                Text.fontSize(13);
                                Text.fontColor('#9AA8B2');
                                Text.margin({ top: 4 });
                            }, Text);
                            Text.pop();
                            Column.pop();
                            Row.pop();
                        };
                        this.forEachUpdateFunction(elmtId, this.reminders, forEachItemGenFunction, (r: ReminderItem) => r.id, false, false);
                    }, ForEach);
                    ForEach.pop();
                    Column.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.appt === null) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('还没有陪诊安排，回到首页跟我说一句就行');
                        Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(313:13)", "entry");
                        Text.fontSize(19);
                        Text.fontColor('#7A8A96');
                        Text.margin({ top: 60 });
                    }, Text);
                    Text.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        Column.pop();
        Scroll.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 挂号确认分两步：先跳转官方渠道，用户回来后再点"已完成"
            if (this.appt !== null && !this.confirmed) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.debugLine("entry/src/main/ets/pages/JourneyPage.ets(327:9)", "entry");
                        Column.width('100%');
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(`这是我帮您选好的方案，还需要去${this.appt.officialChannelName}上确认才算真的挂上号`);
                        Text.debugLine("entry/src/main/ets/pages/JourneyPage.ets(328:11)", "entry");
                        Text.fontSize(15);
                        Text.fontColor('#7A8A96');
                        Text.width('88%');
                        Text.margin({ bottom: 10 });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel(`跳转${this.appt.officialChannelName}确认`);
                        Button.debugLine("entry/src/main/ets/pages/JourneyPage.ets(334:11)", "entry");
                        Button.fontSize(20);
                        Button.width('88%');
                        Button.height(58);
                        Button.borderRadius(29);
                        Button.backgroundColor('#2E6F8E');
                        Button.margin({ bottom: 12 });
                        Button.onClick(() => {
                            this.onGoToOfficialChannel();
                        });
                    }, Button);
                    Button.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('我已经在官方完成确认了');
                        Button.debugLine("entry/src/main/ets/pages/JourneyPage.ets(345:11)", "entry");
                        Button.fontSize(18);
                        Button.width('88%');
                        Button.height(54);
                        Button.borderRadius(27);
                        Button.backgroundColor('#E8874A');
                        Button.margin({ bottom: 24 });
                        Button.onClick(() => {
                            this.onConfirmOfficialDone();
                        });
                    }, Button);
                    Button.pop();
                    Column.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.appt !== null && this.confirmed) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('已确认，提醒已开启');
                        Button.debugLine("entry/src/main/ets/pages/JourneyPage.ets(360:9)", "entry");
                        Button.fontSize(21);
                        Button.width('88%');
                        Button.height(62);
                        Button.borderRadius(31);
                        Button.backgroundColor('#8AA5B4');
                        Button.enabled(false);
                        Button.margin({ bottom: 24 });
                    }, Button);
                    Button.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "JourneyPage";
    }
}
function __Column__cardStyle(): void {
    Column.width('100%');
    Column.padding(18);
    Column.backgroundColor('#FFFFFF');
    Column.borderRadius(16);
    Column.margin({ bottom: 14 });
    Column.alignItems(HorizontalAlign.Start);
}
registerNamedRoute(() => new JourneyPage(undefined, {}), "", { bundleName: "com.example.zhihutongxing", moduleName: "entry", pagePath: "pages/JourneyPage", pageFullPath: "entry/src/main/ets/pages/JourneyPage", integratedHsp: "false", moduleType: "followWithHap" });
