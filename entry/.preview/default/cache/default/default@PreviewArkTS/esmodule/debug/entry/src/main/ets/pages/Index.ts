if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface Index_Params {
    chats?: ChatItem[];
    progress?: ProgressItem[];
    listening?: boolean;
    busy?: boolean;
    inputText?: string;
    pendingRecord?: ServiceRecord | null;
    capturingOcr?: boolean;
    central?: CentralAgent;
    scroller?: Scroller;
}
import router from "@ohos:router";
import type common from "@ohos:app.ability.common";
import photoAccessHelper from "@ohos:file.photoAccessHelper";
import image from "@ohos:multimedia.image";
import fileIo from "@ohos:file.fs";
import { BusEvent, RecordSource } from "@bundle:com.example.zhihutongxing/entry/ets/core/AgentTypes";
import type { RuntimeContext, BusMessage, TaskPlan, TaskNode, AgentResult, ServiceRecord } from "@bundle:com.example.zhihutongxing/entry/ets/core/AgentTypes";
import { eventBus } from "@bundle:com.example.zhihutongxing/entry/ets/core/EventBus";
import { CentralAgent } from "@bundle:com.example.zhihutongxing/entry/ets/agents/CentralAgent";
import { ContextStore } from "@bundle:com.example.zhihutongxing/entry/ets/core/ContextStore";
import { DeviceSyncService } from "@bundle:com.example.zhihutongxing/entry/ets/services/DeviceSyncService";
import { WeatherService } from "@bundle:com.example.zhihutongxing/entry/ets/services/WeatherService";
import { OcrCaptureService } from "@bundle:com.example.zhihutongxing/entry/ets/services/OcrCaptureService";
/** 对话气泡 */
class ChatItem {
    role: string = 'assistant'; // user / assistant
    text: string = '';
    constructor(role: string, text: string) {
        this.role = role;
        this.text = text;
    }
}
/** 进度条目 */
class ProgressItem {
    taskId: string = '';
    title: string = '';
    status: string = 'PENDING';
    constructor(taskId: string, title: string, status: string) {
        this.taskId = taskId;
        this.title = title;
        this.status = status;
    }
}
class Index extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__chats = new ObservedPropertyObjectPU([], this, "chats");
        this.__progress = new ObservedPropertyObjectPU([], this, "progress");
        this.__listening = new ObservedPropertySimplePU(false, this, "listening");
        this.__busy = new ObservedPropertySimplePU(false, this, "busy");
        this.__inputText = new ObservedPropertySimplePU('', this, "inputText");
        this.__pendingRecord = new ObservedPropertyObjectPU(null, this, "pendingRecord");
        this.__capturingOcr = new ObservedPropertySimplePU(false, this, "capturingOcr");
        this.central = new CentralAgent();
        this.scroller = new Scroller();
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: Index_Params) {
        if (params.chats !== undefined) {
            this.chats = params.chats;
        }
        if (params.progress !== undefined) {
            this.progress = params.progress;
        }
        if (params.listening !== undefined) {
            this.listening = params.listening;
        }
        if (params.busy !== undefined) {
            this.busy = params.busy;
        }
        if (params.inputText !== undefined) {
            this.inputText = params.inputText;
        }
        if (params.pendingRecord !== undefined) {
            this.pendingRecord = params.pendingRecord;
        }
        if (params.capturingOcr !== undefined) {
            this.capturingOcr = params.capturingOcr;
        }
        if (params.central !== undefined) {
            this.central = params.central;
        }
        if (params.scroller !== undefined) {
            this.scroller = params.scroller;
        }
    }
    updateStateVars(params: Index_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__chats.purgeDependencyOnElmtId(rmElmtId);
        this.__progress.purgeDependencyOnElmtId(rmElmtId);
        this.__listening.purgeDependencyOnElmtId(rmElmtId);
        this.__busy.purgeDependencyOnElmtId(rmElmtId);
        this.__inputText.purgeDependencyOnElmtId(rmElmtId);
        this.__pendingRecord.purgeDependencyOnElmtId(rmElmtId);
        this.__capturingOcr.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__chats.aboutToBeDeleted();
        this.__progress.aboutToBeDeleted();
        this.__listening.aboutToBeDeleted();
        this.__busy.aboutToBeDeleted();
        this.__inputText.aboutToBeDeleted();
        this.__pendingRecord.aboutToBeDeleted();
        this.__capturingOcr.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __chats: ObservedPropertyObjectPU<ChatItem[]>;
    get chats() {
        return this.__chats.get();
    }
    set chats(newValue: ChatItem[]) {
        this.__chats.set(newValue);
    }
    private __progress: ObservedPropertyObjectPU<ProgressItem[]>;
    get progress() {
        return this.__progress.get();
    }
    set progress(newValue: ProgressItem[]) {
        this.__progress.set(newValue);
    }
    private __listening: ObservedPropertySimplePU<boolean>;
    get listening() {
        return this.__listening.get();
    }
    set listening(newValue: boolean) {
        this.__listening.set(newValue);
    }
    private __busy: ObservedPropertySimplePU<boolean>;
    get busy() {
        return this.__busy.get();
    }
    set busy(newValue: boolean) {
        this.__busy.set(newValue);
    }
    private __inputText: ObservedPropertySimplePU<string>;
    get inputText() {
        return this.__inputText.get();
    }
    set inputText(newValue: string) {
        this.__inputText.set(newValue);
    }
    private __pendingRecord: ObservedPropertyObjectPU<ServiceRecord | null>; // 拍照识别出的待确认病历
    get pendingRecord() {
        return this.__pendingRecord.get();
    }
    set pendingRecord(newValue: ServiceRecord | null) {
        this.__pendingRecord.set(newValue);
    }
    private __capturingOcr: ObservedPropertySimplePU<boolean>;
    get capturingOcr() {
        return this.__capturingOcr.get();
    }
    set capturingOcr(newValue: boolean) {
        this.__capturingOcr.set(newValue);
    }
    private central: CentralAgent;
    private scroller: Scroller;
    aboutToAppear(): void {
        this.initServices();
        this.bindEvents();
        this.chats.push(new ChatItem('assistant', '您好，我是智护同行。您要去医院看病、取药，直接跟我说一句就行'));
    }
    aboutToDisappear(): void {
        eventBus.clear();
        DeviceSyncService.clearReminders();
    }
    private async initServices(): Promise<void> {
        const ctx = getContext(this) as common.UIAbilityContext;
        await ContextStore.getInstance().init(ctx);
        DeviceSyncService.start();
        await this.seedDemoProfile();
    }
    /** 演示用：预置一份用户档案与一条历史就诊记录 */
    private async seedDemoProfile(): Promise<void> {
        const store: ContextStore = ContextStore.getInstance();
        const p = store.getProfile();
        if (p.name.length > 0) {
            return;
        }
        await store.saveProfile({
            name: '张秀兰',
            age: 72,
            homeAddress: '幸福小区3栋2单元',
            preferredHospitals: ['市第一人民医院'],
            chronicTags: ['高血压'],
            accessibilityMode: true,
            emergencyContact: '13800000000'
        });
        await store.addRecord({
            recordId: 'r001',
            hospital: '市第一人民医院',
            department: '心血管内科',
            doctorName: '王建国 主任医师',
            visitDate: '2026-07-20',
            followUpDays: 30,
            prescription: '苯磺酸氨氯地平片 每日1次 每次5mg',
            source: RecordSource.MANUAL_INPUT,
            confirmed: true // 演示数据视为已核实，真实场景下必须走用户确认
        });
    }
    /** 订阅 Agent 层事件，驱动 UI 更新 */
    private bindEvents(): void {
        eventBus.on(BusEvent.PLAN_UPDATED, (msg: BusMessage) => {
            const plan: TaskPlan = JSON.parse(msg.payload) as TaskPlan;
            const list: ProgressItem[] = [];
            for (let i = 0; i < plan.nodes.length; i++) {
                const n: TaskNode = plan.nodes[i];
                list.push(new ProgressItem(n.id, n.title, n.status as string));
            }
            this.progress = list;
        });
        eventBus.on(BusEvent.TASK_STARTED, (msg: BusMessage) => {
            const obj: Record<string, string> = JSON.parse(msg.payload) as Record<string, string>;
            this.updateProgress(obj['taskId'], 'RUNNING');
        });
        eventBus.on(BusEvent.TASK_FINISHED, (msg: BusMessage) => {
            const r: AgentResult = JSON.parse(msg.payload) as AgentResult;
            this.updateProgress(r.taskId, r.success ? 'SUCCESS' : 'FAILED');
        });
        eventBus.on(BusEvent.SPEAK, (msg: BusMessage) => {
            const obj: Record<string, string> = JSON.parse(msg.payload) as Record<string, string>;
            this.pushChat('assistant', obj['text']);
        });
        eventBus.on(BusEvent.ANOMALY_DETECTED, () => {
            this.progress = [];
        });
    }
    private updateProgress(taskId: string, status: string): void {
        const list: ProgressItem[] = [];
        for (let i = 0; i < this.progress.length; i++) {
            const p: ProgressItem = this.progress[i];
            if (p.taskId === taskId) {
                list.push(new ProgressItem(p.taskId, p.title, status));
            }
            else {
                list.push(p);
            }
        }
        this.progress = list;
    }
    private pushChat(role: string, text: string): void {
        this.chats.push(new ChatItem(role, text));
        setTimeout(() => {
            this.scroller.scrollEdge(Edge.Bottom);
        }, 80);
    }
    /** 发起一次请求 */
    private async submit(text: string): Promise<void> {
        if (text.length === 0 || this.busy) {
            return;
        }
        this.busy = true;
        this.pushChat('user', text);
        this.inputText = '';
        try {
            const rt: RuntimeContext = await this.buildRuntimeContext();
            const clarify: string = await this.central.handleUserRequest(text, rt);
            if (clarify.length > 0) {
                this.pushChat('assistant', clarify);
            }
        }
        catch (e) {
            this.pushChat('assistant', '刚才没处理好，您再说一次好吗');
            console.error(`[Index] submit error: ${e}`);
        }
        finally {
            this.busy = false;
        }
    }
    // ==================== 拍照录入病历 ====================
    /**
     * 用户点"拍照录入"：选照片 → OCR → 大模型结构化 → 弹出待确认卡片
     * 全程不直接写入正式病历，必须等用户点"确认无误"才生效（见 onConfirmPendingRecord）
     */
    private async onCapturePhoto(): Promise<void> {
        if (this.capturingOcr) {
            return;
        }
        this.capturingOcr = true;
        try {
            const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
            const result = await picker.select({
                MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
                maxSelectNumber: 1
            });
            if (result.photoUris === undefined || result.photoUris.length === 0) {
                this.capturingOcr = false;
                return;
            }
            const pixelMap: image.PixelMap = await this.loadPixelMap(result.photoUris[0]);
            const record: ServiceRecord | null = await OcrCaptureService.captureFromPhoto(pixelMap);
            if (record === null) {
                this.pushChat('assistant', '这张照片没能识别出病历信息，要不换一张清楚点的试试');
            }
            else {
                this.pendingRecord = record;
            }
        }
        catch (e) {
            console.error(`[Index] capture photo failed: ${e}`);
            this.pushChat('assistant', '拍照识别没成功，您可以再试一次');
        }
        finally {
            this.capturingOcr = false;
        }
    }
    /** 把照片 URI 读成 PixelMap，供 OCR 使用 */
    private async loadPixelMap(uri: string): Promise<image.PixelMap> {
        const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
        try {
            const source: image.ImageSource = image.createImageSource(file.fd);
            const pixelMap: image.PixelMap = await source.createPixelMap();
            await source.release();
            return pixelMap;
        }
        finally {
            await fileIo.close(file.fd);
        }
    }
    /** 用户点"确认无误"：这时候才真正写入病历库 */
    private async onConfirmPendingRecord(): Promise<void> {
        if (this.pendingRecord === null) {
            return;
        }
        const confirmed: ServiceRecord = {
            recordId: this.pendingRecord.recordId,
            hospital: this.pendingRecord.hospital,
            department: this.pendingRecord.department,
            doctorName: this.pendingRecord.doctorName,
            visitDate: this.pendingRecord.visitDate,
            followUpDays: this.pendingRecord.followUpDays,
            prescription: this.pendingRecord.prescription,
            source: this.pendingRecord.source,
            confirmed: true
        };
        await ContextStore.getInstance().addRecord(confirmed);
        this.pushChat('assistant', `已经把${confirmed.hospital}${confirmed.department}这次的记录存好了`);
        this.pendingRecord = null;
    }
    private onDiscardPendingRecord(): void {
        this.pendingRecord = null;
    }
    /**
     * 采集当前上下文：位置、天气、时间
     *
     * ⚠️ 定位目前仍是写死的经纬度（杭州附近）。
     * 要接真实定位，需要在 module.json5 里已经声明的 LOCATION 权限基础上，
     * 调用 @kit.LocationKit 的 geoLocationManager.getCurrentLocation() 获取真实经纬度，
     * 这里先用固定坐标，保证没有定位权限时也能跑通全流程演示。
     */
    private async buildRuntimeContext(): Promise<RuntimeContext> {
        const profile = ContextStore.getInstance().getProfile();
        const lat: number = 30.2741;
        const lng: number = 120.1551;
        // 天气改为真实接口（未配置 Key 时自动降级为 Mock，见 WeatherService.ets）
        const weather: string = await WeatherService.getWeather();
        return {
            currentLat: lat,
            currentLng: lng,
            currentAddress: profile.homeAddress,
            nowTs: Date.now(),
            weather: weather,
            trafficLevel: '缓行'
        };
    }
    /** 模拟语音输入 */
    private onVoiceTap(): void {
        if (this.busy) {
            return;
        }
        this.listening = true;
        // TODO: 接入系统语音识别，此处用固定语料模拟
        setTimeout(() => {
            this.listening = false;
            this.submit('我要去第一人民医院拿高血压药');
        }, 1200);
    }
    // ==================== UI ====================
    ChatBubble(item: ChatItem, parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Index.ets(305:5)", "entry");
            Row.width('100%');
            Row.margin({ bottom: 14 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (item.role === 'user') {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Blank.create();
                        Blank.debugLine("entry/src/main/ets/pages/Index.ets(307:9)", "entry");
                    }, Blank);
                    Blank.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(item.text);
                        Text.debugLine("entry/src/main/ets/pages/Index.ets(308:9)", "entry");
                        Text.fontSize(21);
                        Text.fontColor('#FFFFFF');
                        Text.padding({ left: 18, right: 18, top: 14, bottom: 14 });
                        Text.backgroundColor('#2E6F8E');
                        Text.borderRadius(18);
                        Text.constraintSize({ maxWidth: '78%' });
                    }, Text);
                    Text.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(item.text);
                        Text.debugLine("entry/src/main/ets/pages/Index.ets(316:9)", "entry");
                        Text.fontSize(21);
                        Text.fontColor('#22303C');
                        Text.lineHeight(32);
                        Text.padding({ left: 18, right: 18, top: 14, bottom: 14 });
                        Text.backgroundColor('#FFFFFF');
                        Text.borderRadius(18);
                        Text.constraintSize({ maxWidth: '82%' });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Blank.create();
                        Blank.debugLine("entry/src/main/ets/pages/Index.ets(324:9)", "entry");
                    }, Blank);
                    Blank.pop();
                });
            }
        }, If);
        If.pop();
        Row.pop();
    }
    PendingInfoRow(label: string, value: string, parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Index.ets(333:5)", "entry");
            Row.width('100%');
            Row.padding({ top: 6, bottom: 6 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(label);
            Text.debugLine("entry/src/main/ets/pages/Index.ets(334:7)", "entry");
            Text.fontSize(16);
            Text.fontColor('#7A8A96');
            Text.width(70);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(value.length > 0 ? value : '未识别到，可稍后手动补充');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(338:7)", "entry");
            Text.fontSize(16);
            Text.fontColor(value.length > 0 ? '#22303C' : '#B0BAC2');
            Text.layoutWeight(1);
        }, Text);
        Text.pop();
        Row.pop();
    }
    ProgressRow(item: ProgressItem, parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Index.ets(349:5)", "entry");
            Row.width('100%');
            Row.padding({ top: 10, bottom: 10 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.statusIcon(item.status));
            Text.debugLine("entry/src/main/ets/pages/Index.ets(350:7)", "entry");
            Text.fontSize(20);
            Text.width(34);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(item.title);
            Text.debugLine("entry/src/main/ets/pages/Index.ets(353:7)", "entry");
            Text.fontSize(19);
            Text.fontColor(item.status === 'SUCCESS' ? '#3B7A57' : '#4A5A66');
            Text.layoutWeight(1);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.statusLabel(item.status));
            Text.debugLine("entry/src/main/ets/pages/Index.ets(357:7)", "entry");
            Text.fontSize(16);
            Text.fontColor('#8A9AA6');
        }, Text);
        Text.pop();
        Row.pop();
    }
    private statusIcon(s: string): string {
        if (s === 'SUCCESS') {
            return '✓';
        }
        if (s === 'RUNNING') {
            return '◐';
        }
        if (s === 'FAILED') {
            return '!';
        }
        return '○';
    }
    private statusLabel(s: string): string {
        if (s === 'SUCCESS') {
            return '已完成';
        }
        if (s === 'RUNNING') {
            return '处理中';
        }
        if (s === 'FAILED') {
            return '未成功';
        }
        return '等待中';
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Index.ets(392:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor('#EEF3F6');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 顶部标题
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Index.ets(394:7)", "entry");
            // 顶部标题
            Row.width('100%');
            // 顶部标题
            Row.padding({ left: 20, right: 20, top: 16, bottom: 12 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Index.ets(395:9)", "entry");
            Column.alignItems(HorizontalAlign.Start);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('智护同行');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(396:11)", "entry");
            Text.fontSize(26);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#1B2A34');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('说一句话，我来安排');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(400:11)", "entry");
            Text.fontSize(15);
            Text.fontColor('#7A8A96');
            Text.margin({ top: 2 });
        }, Text);
        Text.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/Index.ets(406:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('陪诊记录');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(407:9)", "entry");
            Text.fontSize(16);
            Text.fontColor('#2E6F8E');
            Text.onClick(() => {
                router.pushUrl({ url: 'pages/JourneyPage' });
            });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('拍照录入');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(413:9)", "entry");
            Text.fontSize(16);
            Text.fontColor('#2E6F8E');
            Text.margin({ left: 16 });
            Text.onClick(() => {
                this.onCapturePhoto();
            });
        }, Text);
        Text.pop();
        // 顶部标题
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 拍照识别待确认卡片 —— 识别结果不直接生效，必须用户点确认
            if (this.pendingRecord !== null) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.debugLine("entry/src/main/ets/pages/Index.ets(426:9)", "entry");
                        Column.width('90%');
                        Column.padding(18);
                        Column.backgroundColor('#FFFFFF');
                        Column.borderRadius(16);
                        Column.margin({ bottom: 12 });
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create();
                        Row.debugLine("entry/src/main/ets/pages/Index.ets(427:11)", "entry");
                        Row.width('100%');
                        Row.margin({ bottom: 10 });
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('识别到一条病历，麻烦您看看对不对');
                        Text.debugLine("entry/src/main/ets/pages/Index.ets(428:13)", "entry");
                        Text.fontSize(17);
                        Text.fontWeight(FontWeight.Medium);
                        Text.fontColor('#1B2A34');
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Blank.create();
                        Blank.debugLine("entry/src/main/ets/pages/Index.ets(432:13)", "entry");
                    }, Blank);
                    Blank.pop();
                    Row.pop();
                    this.PendingInfoRow.bind(this)('医院', this.pendingRecord.hospital);
                    this.PendingInfoRow.bind(this)('科室', this.pendingRecord.department);
                    this.PendingInfoRow.bind(this)('医生', this.pendingRecord.doctorName);
                    this.PendingInfoRow.bind(this)('日期', this.pendingRecord.visitDate);
                    this.PendingInfoRow.bind(this)('用药', this.pendingRecord.prescription);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create();
                        Row.debugLine("entry/src/main/ets/pages/Index.ets(443:11)", "entry");
                        Row.width('100%');
                        Row.margin({ top: 12 });
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('不对，取消');
                        Button.debugLine("entry/src/main/ets/pages/Index.ets(444:13)", "entry");
                        Button.fontSize(16);
                        Button.fontColor('#7A8A96');
                        Button.backgroundColor('#EEF3F6');
                        Button.layoutWeight(1);
                        Button.margin({ right: 10 });
                        Button.onClick(() => {
                            this.onDiscardPendingRecord();
                        });
                    }, Button);
                    Button.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('确认无误');
                        Button.debugLine("entry/src/main/ets/pages/Index.ets(453:13)", "entry");
                        Button.fontSize(16);
                        Button.fontColor('#FFFFFF');
                        Button.backgroundColor('#2E6F8E');
                        Button.layoutWeight(1);
                        Button.onClick(() => {
                            this.onConfirmPendingRecord();
                        });
                    }, Button);
                    Button.pop();
                    Row.pop();
                    Column.pop();
                });
            }
            // 进度面板：让用户看见 Agent 正在替他做什么
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 进度面板：让用户看见 Agent 正在替他做什么
            if (this.progress.length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.debugLine("entry/src/main/ets/pages/Index.ets(474:9)", "entry");
                        Column.width('90%');
                        Column.padding(18);
                        Column.backgroundColor('#FFFFFF');
                        Column.borderRadius(16);
                        Column.margin({ bottom: 12 });
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('正在为您安排');
                        Text.debugLine("entry/src/main/ets/pages/Index.ets(475:11)", "entry");
                        Text.fontSize(17);
                        Text.fontColor('#5A6A76');
                        Text.width('100%');
                        Text.margin({ bottom: 4 });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        ForEach.create();
                        const forEachItemGenFunction = _item => {
                            const item = _item;
                            this.ProgressRow.bind(this)(item);
                        };
                        this.forEachUpdateFunction(elmtId, this.progress, forEachItemGenFunction, (item: ProgressItem) => item.taskId, false, false);
                    }, ForEach);
                    ForEach.pop();
                    Column.pop();
                });
            }
            // 对话区
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 对话区
            Scroll.create(this.scroller);
            Scroll.debugLine("entry/src/main/ets/pages/Index.ets(492:7)", "entry");
            // 对话区
            Scroll.layoutWeight(1);
            // 对话区
            Scroll.scrollBar(BarState.Off);
        }, Scroll);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Index.ets(493:9)", "entry");
            Column.width('100%');
            Column.padding({ left: 18, right: 18 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = (_item, idx: number) => {
                const item = _item;
                this.ChatBubble.bind(this)(item);
            };
            this.forEachUpdateFunction(elmtId, this.chats, forEachItemGenFunction, (item: ChatItem, idx: number) => `${idx}_${item.text.length}`, true, true);
        }, ForEach);
        ForEach.pop();
        Column.pop();
        // 对话区
        Scroll.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 底部输入区
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Index.ets(505:7)", "entry");
            // 底部输入区
            Column.width('100%');
            // 底部输入区
            Column.padding({ top: 12, bottom: 22 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Index.ets(506:9)", "entry");
            Row.width('92%');
            Row.margin({ bottom: 14 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextInput.create({ text: this.inputText, placeholder: '也可以打字告诉我' });
            TextInput.debugLine("entry/src/main/ets/pages/Index.ets(507:11)", "entry");
            TextInput.fontSize(19);
            TextInput.height(52);
            TextInput.layoutWeight(1);
            TextInput.backgroundColor('#FFFFFF');
            TextInput.borderRadius(26);
            TextInput.onChange((v: string) => {
                this.inputText = v;
            });
        }, TextInput);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('发送');
            Button.debugLine("entry/src/main/ets/pages/Index.ets(516:11)", "entry");
            Button.fontSize(18);
            Button.height(52);
            Button.margin({ left: 10 });
            Button.backgroundColor('#2E6F8E');
            Button.onClick(() => {
                this.submit(this.inputText);
            });
        }, Button);
        Button.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 大号语音按钮 —— 老人主要入口
            Button.createWithChild();
            Button.debugLine("entry/src/main/ets/pages/Index.ets(529:9)", "entry");
            // 大号语音按钮 —— 老人主要入口
            Button.width('84%');
            // 大号语音按钮 —— 老人主要入口
            Button.height(72);
            // 大号语音按钮 —— 老人主要入口
            Button.borderRadius(36);
            // 大号语音按钮 —— 老人主要入口
            Button.backgroundColor(this.listening ? '#1F566E' : '#2E6F8E');
            // 大号语音按钮 —— 老人主要入口
            Button.enabled(!this.busy);
            // 大号语音按钮 —— 老人主要入口
            Button.onClick(() => {
                this.onVoiceTap();
            });
        }, Button);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Index.ets(530:11)", "entry");
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.listening ? '正在听…' : '按住说话');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(531:13)", "entry");
            Text.fontSize(23);
            Text.fontColor('#FFFFFF');
            Text.fontWeight(FontWeight.Medium);
        }, Text);
        Text.pop();
        Column.pop();
        // 大号语音按钮 —— 老人主要入口
        Button.pop();
        // 底部输入区
        Column.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "Index";
    }
}
registerNamedRoute(() => new Index(undefined, {}), "", { bundleName: "com.example.zhihutongxing", moduleName: "entry", pagePath: "pages/Index", pageFullPath: "entry/src/main/ets/pages/Index", integratedHsp: "false", moduleType: "followWithHap" });
