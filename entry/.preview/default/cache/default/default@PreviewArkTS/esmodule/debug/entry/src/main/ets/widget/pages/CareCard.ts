if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface CareCard_Params {
    hasPlan?: boolean;
    title?: string;
    nextAction?: string;
    detail?: string;
    hospital?: string;
    stepIndex?: number;
    stepTotal?: number;
}
/**
 * 智护同行 - 桌面卡片 UI
 *
 * 设计约束（老年用户 + 卡片尺寸有限）：
 *  1. 只显示"下一步该做什么"，不做信息罗列
 *  2. 字号尽量大，一眼能看清
 *  3. 点击任意位置直接拉起 App，不设小按钮
 */
const storage = new LocalStorage();
class CareCard extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: CareCard_Params) {
    }
    updateStateVars(params: CareCard_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__hasPlan.purgeDependencyOnElmtId(rmElmtId);
        this.__title.purgeDependencyOnElmtId(rmElmtId);
        this.__nextAction.purgeDependencyOnElmtId(rmElmtId);
        this.__detail.purgeDependencyOnElmtId(rmElmtId);
        this.__hospital.purgeDependencyOnElmtId(rmElmtId);
        this.__stepIndex.purgeDependencyOnElmtId(rmElmtId);
        this.__stepTotal.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__hasPlan.aboutToBeDeleted();
        this.__title.aboutToBeDeleted();
        this.__nextAction.aboutToBeDeleted();
        this.__detail.aboutToBeDeleted();
        this.__hospital.aboutToBeDeleted();
        this.__stepIndex.aboutToBeDeleted();
        this.__stepTotal.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __hasPlan: ObservedPropertyAbstractPU<boolean> = this.createLocalStorageProp<boolean>('hasPlan', false, "hasPlan");
    get hasPlan() {
        return this.__hasPlan.get();
    }
    set hasPlan(newValue: boolean) {
        this.__hasPlan.set(newValue);
    }
    private __title: ObservedPropertyAbstractPU<string> = this.createLocalStorageProp<string>('title', '还没有陪诊安排', "title");
    get title() {
        return this.__title.get();
    }
    set title(newValue: string) {
        this.__title.set(newValue);
    }
    private __nextAction: ObservedPropertyAbstractPU<string> = this.createLocalStorageProp<string>('nextAction', '点一下，说句话就能安排', "nextAction");
    get nextAction() {
        return this.__nextAction.get();
    }
    set nextAction(newValue: string) {
        this.__nextAction.set(newValue);
    }
    private __detail: ObservedPropertyAbstractPU<string> = this.createLocalStorageProp<string>('detail', '', "detail");
    get detail() {
        return this.__detail.get();
    }
    set detail(newValue: string) {
        this.__detail.set(newValue);
    }
    private __hospital: ObservedPropertyAbstractPU<string> = this.createLocalStorageProp<string>('hospital', '', "hospital");
    get hospital() {
        return this.__hospital.get();
    }
    set hospital(newValue: string) {
        this.__hospital.set(newValue);
    }
    private __stepIndex: ObservedPropertyAbstractPU<number> = this.createLocalStorageProp<number>('stepIndex', 0, "stepIndex");
    get stepIndex() {
        return this.__stepIndex.get();
    }
    set stepIndex(newValue: number) {
        this.__stepIndex.set(newValue);
    }
    private __stepTotal: ObservedPropertyAbstractPU<number> = this.createLocalStorageProp<number>('stepTotal', 0, "stepTotal");
    get stepTotal() {
        return this.__stepTotal.get();
    }
    set stepTotal(newValue: number) {
        this.__stepTotal.set(newValue);
    }
    /** 点击卡片拉起主应用 */
    private openApp(): void {
        postCardAction(this, {
            action: 'router',
            abilityName: 'EntryAbility',
            params: {
                'from': 'card'
            }
        });
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(35:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.padding(16);
            Column.alignItems(HorizontalAlign.Start);
            Column.backgroundColor('#FFFFFF');
            Column.borderRadius(20);
            Column.onClick(() => {
                this.openApp();
            });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 顶部品牌行
            Row.create();
            Row.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(37:7)", "entry");
            // 顶部品牌行
            Row.width('100%');
            // 顶部品牌行
            Row.margin({ bottom: 8 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('智护同行');
            Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(38:9)", "entry");
            Text.fontSize(13);
            Text.fontColor('#7A8A96');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(41:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.hasPlan && this.stepTotal > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(`${this.stepIndex}/${this.stepTotal}`);
                        Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(43:11)", "entry");
                        Text.fontSize(12);
                        Text.fontColor('#2E6F8E');
                        Text.padding({ left: 7, right: 7, top: 2, bottom: 2 });
                        Text.backgroundColor('#E3EEF4');
                        Text.borderRadius(8);
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
        // 顶部品牌行
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.hasPlan) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        // 主信息：下一步动作，最大字号
                        Text.create(this.nextAction);
                        Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(56:9)", "entry");
                        // 主信息：下一步动作，最大字号
                        Text.fontSize(22);
                        // 主信息：下一步动作，最大字号
                        Text.fontWeight(FontWeight.Bold);
                        // 主信息：下一步动作，最大字号
                        Text.fontColor('#1B2A34');
                        // 主信息：下一步动作，最大字号
                        Text.width('100%');
                        // 主信息：下一步动作，最大字号
                        Text.maxLines(1);
                        // 主信息：下一步动作，最大字号
                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                    }, Text);
                    // 主信息：下一步动作，最大字号
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.title);
                        Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(64:9)", "entry");
                        Text.fontSize(15);
                        Text.fontColor('#4A5A66');
                        Text.width('100%');
                        Text.maxLines(1);
                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                        Text.margin({ top: 5 });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        if (this.detail.length > 0) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Text.create(this.detail);
                                    Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(73:11)", "entry");
                                    Text.fontSize(13);
                                    Text.fontColor('#E8874A');
                                    Text.width('100%');
                                    Text.maxLines(2);
                                    Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                                    Text.margin({ top: 6 });
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
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Blank.create();
                        Blank.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(82:9)", "entry");
                    }, Blank);
                    Blank.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        if (this.hospital.length > 0) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Text.create(this.hospital);
                                    Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(85:11)", "entry");
                                    Text.fontSize(12);
                                    Text.fontColor('#8A9AA6');
                                    Text.width('100%');
                                    Text.maxLines(1);
                                    Text.textOverflow({ overflow: TextOverflow.Ellipsis });
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
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        // 空态：引导用户开口
                        Column.create();
                        Column.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(94:9)", "entry");
                        // 空态：引导用户开口
                        Column.width('100%');
                        // 空态：引导用户开口
                        Column.layoutWeight(1);
                        // 空态：引导用户开口
                        Column.justifyContent(FlexAlign.Center);
                        // 空态：引导用户开口
                        Column.alignItems(HorizontalAlign.Start);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.title);
                        Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(95:11)", "entry");
                        Text.fontSize(18);
                        Text.fontWeight(FontWeight.Medium);
                        Text.fontColor('#4A5A66');
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.nextAction);
                        Text.debugLine("entry/src/main/ets/widget/pages/CareCard.ets(99:11)", "entry");
                        Text.fontSize(14);
                        Text.fontColor('#8A9AA6');
                        Text.margin({ top: 6 });
                    }, Text);
                    Text.pop();
                    // 空态：引导用户开口
                    Column.pop();
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
        return "CareCard";
    }
}
ViewStackProcessor.StartGetAccessRecordingFor(ViewStackProcessor.AllocateNewElmetIdForNextComponent());
loadEtsCard(new CareCard(undefined, {}, storage), "com.whatpressure.zhihutongxing/entry/ets/widget/pages/CareCard");
ViewStackProcessor.StopGetAccessRecording();
