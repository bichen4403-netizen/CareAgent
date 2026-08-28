/**
 * 智护同行 - 主界面
 *
 * 设计原则（老年用户）：
 *  1. 一个巨大的语音按钮，不需要找入口
 *  2. 字号 ≥ 20fp，对比度高
 *  3. 每一步只呈现一个决策点，不堆信息
 *  4. 全流程进度可视，让用户知道"系统正在替我做什么"
 */

import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  RuntimeContext, BusEvent, BusMessage, TaskPlan, TaskNode, TaskStatus, AgentResult,
  ServiceRecord, RecordSource
} from '../core/AgentTypes';
import { eventBus } from '../core/EventBus';
import { CentralAgent } from '../agents/CentralAgent';
import { ContextStore } from '../core/ContextStore';
import { DeviceSyncService } from '../services/DeviceSyncService';
import { WeatherService } from '../services/WeatherService';
import { OcrCaptureService } from '../services/OcrCaptureService';

/** 对话气泡 */
class ChatItem {
  role: string = 'assistant';   // user / assistant
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

/**
 * 页面自己注册过的总线监听记录，供 aboutToDisappear 精确解绑用。
 * ArkTS 不允许匿名对象字面量当类型（arkts-no-obj-literals-as-types），必须显式声明接口。
 */
interface BoundHandler {
  event: BusEvent;
  handler: (msg: BusMessage) => void;
}

@Entry
@Component
struct Index {
  @State chats: ChatItem[] = [];
  @State progress: ProgressItem[] = [];
  @State listening: boolean = false;
  @State busy: boolean = false;
  @State inputText: string = '';
  @State pendingRecord: ServiceRecord | null = null;   // 拍照识别出的待确认病历
  @State capturingOcr: boolean = false;

  private central: CentralAgent = CentralAgent.getInstance();
  private scroller: Scroller = new Scroller();

  /**
   * eventBus 是全局单例，DeviceSyncService 等页面外的模块也订阅在同一条总线上。
   * 之前 aboutToDisappear 直接 eventBus.clear() 会把它们的监听器一并清空，
   * 而 DeviceSyncService.start() 有"只初始化一次"的幂等标记，被清空后不会自动重新挂载，
   * 一旦 Index 被系统回收重建过一次，语音播报和设备通知就会永久失效且没有任何报错。
   * 这里改成只记录、只解绑本页面自己注册的 handler，不影响总线上的其它订阅者。
   */
  private boundHandlers: BoundHandler[] = [];

  aboutToAppear(): void {
    this.initServices();
    this.bindEvents();
    this.chats.push(new ChatItem('assistant',
      '您好，我是智护同行。您要去医院看病、取药，直接跟我说一句就行'));
  }

  aboutToDisappear(): void {
    for (let i = 0; i < this.boundHandlers.length; i++) {
      const b = this.boundHandlers[i];
      eventBus.off(b.event, b.handler);
    }
    this.boundHandlers = [];
    DeviceSyncService.clearReminders();
  }

  /** 注册一个总线监听，并记下来供 aboutToDisappear 精确解绑 */
  private on(event: BusEvent, handler: (msg: BusMessage) => void): void {
    eventBus.on(event, handler);
    const entry: BoundHandler = { event: event, handler: handler };
    this.boundHandlers.push(entry);
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
      confirmed: true   // 演示数据视为已核实，真实场景下必须走用户确认
    });
  }

  /** 订阅 Agent 层事件，驱动 UI 更新 */
  private bindEvents(): void {
    this.on(BusEvent.PLAN_UPDATED, (msg: BusMessage) => {
      const plan: TaskPlan = JSON.parse(msg.payload) as TaskPlan;
      const list: ProgressItem[] = [];
      for (let i = 0; i < plan.nodes.length; i++) {
        const n: TaskNode = plan.nodes[i];
        list.push(new ProgressItem(n.id, n.title, n.status as string));
      }
      this.progress = list;
    });

    this.on(BusEvent.TASK_STARTED, (msg: BusMessage) => {
      const obj: Record<string, string> = JSON.parse(msg.payload) as Record<string, string>;
      this.updateProgress(obj['taskId'], 'RUNNING');
    });

    this.on(BusEvent.TASK_FINISHED, (msg: BusMessage) => {
      const r: AgentResult = JSON.parse(msg.payload) as AgentResult;
      this.updateProgress(r.taskId, r.success ? 'SUCCESS' : 'FAILED');
    });

    this.on(BusEvent.SPEAK, (msg: BusMessage) => {
      const obj: Record<string, string> = JSON.parse(msg.payload) as Record<string, string>;
      this.pushChat('assistant', obj['text']);
    });

    this.on(BusEvent.ANOMALY_DETECTED, () => {
      this.progress = [];
    });
  }

  private updateProgress(taskId: string, status: string): void {
    const list: ProgressItem[] = [];
    for (let i = 0; i < this.progress.length; i++) {
      const p: ProgressItem = this.progress[i];
      if (p.taskId === taskId) {
        list.push(new ProgressItem(p.taskId, p.title, status));
      } else {
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
    } catch (e) {
      this.pushChat('assistant', '刚才没处理好，您再说一次好吗');
      console.error(`[Index] submit error: ${e}`);
    } finally {
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
      } else {
        this.pendingRecord = record;
      }
    } catch (e) {
      console.error(`[Index] capture photo failed: ${e}`);
      this.pushChat('assistant', '拍照识别没成功，您可以再试一次');
    } finally {
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
    } finally {
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

  @Builder
  ChatBubble(item: ChatItem) {
    Row() {
      if (item.role === 'user') {
        Blank()
        Text(item.text)
          .fontSize(21)
          .fontColor('#FFFFFF')
          .padding({ left: 18, right: 18, top: 14, bottom: 14 })
          .backgroundColor('#2E6F8E')
          .borderRadius(18)
          .constraintSize({ maxWidth: '78%' })
      } else {
        Text(item.text)
          .fontSize(21)
          .fontColor('#22303C')
          .lineHeight(32)
          .padding({ left: 18, right: 18, top: 14, bottom: 14 })
          .backgroundColor('#FFFFFF')
          .borderRadius(18)
          .constraintSize({ maxWidth: '82%' })
        Blank()
      }
    }
    .width('100%')
    .margin({ bottom: 14 })
  }

  @Builder
  PendingInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor('#7A8A96')
        .width(70)
      Text(value.length > 0 ? value : '未识别到，可稍后手动补充')
        .fontSize(16)
        .fontColor(value.length > 0 ? '#22303C' : '#B0BAC2')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  ProgressRow(item: ProgressItem) {
    Row() {
      Text(this.statusIcon(item.status))
        .fontSize(20)
        .width(34)
      Text(item.title)
        .fontSize(19)
        .fontColor(item.status === 'SUCCESS' ? '#3B7A57' : '#4A5A66')
        .layoutWeight(1)
      Text(this.statusLabel(item.status))
        .fontSize(16)
        .fontColor('#8A9AA6')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
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

  build() {
    Column() {
      // 顶部标题
      Row() {
        Column() {
          Text('智护同行')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2A34')
          Text('说一句话，我来安排')
            .fontSize(15)
            .fontColor('#7A8A96')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text('陪诊记录')
          .fontSize(16)
          .fontColor('#2E6F8E')
          .onClick(() => {
            router.pushUrl({ url: 'pages/JourneyPage' });
          })
        Text('拍照录入')
          .fontSize(16)
          .fontColor('#2E6F8E')
          .margin({ left: 16 })
          .onClick(() => {
            this.onCapturePhoto();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })

      // 拍照识别待确认卡片 —— 识别结果不直接生效，必须用户点确认
      if (this.pendingRecord !== null) {
        Column() {
          Row() {
            Text('识别到一条病历，麻烦您看看对不对')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1B2A34')
            Blank()
          }
          .width('100%')
          .margin({ bottom: 10 })

          this.PendingInfoRow('医院', this.pendingRecord.hospital)
          this.PendingInfoRow('科室', this.pendingRecord.department)
          this.PendingInfoRow('医生', this.pendingRecord.doctorName)
          this.PendingInfoRow('日期', this.pendingRecord.visitDate)
          this.PendingInfoRow('用药', this.pendingRecord.prescription)

          Row() {
            Button('不对，取消')
              .fontSize(16)
              .fontColor('#7A8A96')
              .backgroundColor('#EEF3F6')
              .layoutWeight(1)
              .margin({ right: 10 })
              .onClick(() => {
                this.onDiscardPendingRecord();
              })
            Button('确认无误')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .backgroundColor('#2E6F8E')
              .layoutWeight(1)
              .onClick(() => {
                this.onConfirmPendingRecord();
              })
          }
          .width('100%')
          .margin({ top: 12 })
        }
        .width('90%')
        .padding(18)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .margin({ bottom: 12 })
      }

      // 进度面板：让用户看见 Agent 正在替他做什么
      if (this.progress.length > 0) {
        Column() {
          Text('正在为您安排')
            .fontSize(17)
            .fontColor('#5A6A76')
            .width('100%')
            .margin({ bottom: 4 })
          ForEach(this.progress, (item: ProgressItem) => {
            this.ProgressRow(item);
          }, (item: ProgressItem) => item.taskId)
        }
        .width('90%')
        .padding(18)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .margin({ bottom: 12 })
      }

      // 对话区
      Scroll(this.scroller) {
        Column() {
          ForEach(this.chats, (item: ChatItem, idx: number) => {
            this.ChatBubble(item);
          }, (item: ChatItem, idx: number) => `${idx}_${item.text.length}`)
        }
        .width('100%')
        .padding({ left: 18, right: 18 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // 底部输入区
      Column() {
        Row() {
          TextInput({ text: this.inputText, placeholder: '也可以打字告诉我' })
            .fontSize(19)
            .height(52)
            .layoutWeight(1)
            .backgroundColor('#FFFFFF')
            .borderRadius(26)
            .onChange((v: string) => {
              this.inputText = v;
            })
          Button('发送')
            .fontSize(18)
            .height(52)
            .margin({ left: 10 })
            .backgroundColor('#2E6F8E')
            .onClick(() => {
              this.submit(this.inputText);
            })
        }
        .width('92%')
        .margin({ bottom: 14 })

        // 大号语音按钮 —— 老人主要入口
        Button() {
          Column() {
            Text(this.listening ? '正在听…' : '按住说话')
              .fontSize(23)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
          }
        }
        .width('84%')
        .height(72)
        .borderRadius(36)
        .backgroundColor(this.listening ? '#1F566E' : '#2E6F8E')
        .enabled(!this.busy)
        .onClick(() => {
          this.onVoiceTap();
        })
      }
      .width('100%')
      .padding({ top: 12, bottom: 22 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#EEF3F6')
  }
}
