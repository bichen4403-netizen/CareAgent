/**
 * 智护同行 - 主界面
 *
 * 设计原则（老年用户）：
 *  1. 一个大语音按钮：点一下开始说，说完停顿会自动结束，也可以再点一下结束
 *  2. 字号 ≥ 18fp，高对比度；助手的话点一下可以再听一遍
 *  3. 每一步只给一个主要决策点：追问时下方直接给出可点的回答
 *  4. 全流程进度可视：看得见“系统正在替我做什么”，数据来源如实标注
 *  5. 主动服务：到期复诊、看完病记录复诊时间，都以卡片形式主动出现
 */

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { call } from '@kit.TelephonyKit';
import {
  BusEvent, BusMessage, TaskPlan, AgentResult, ServiceRecord, RecordSource, AgentReply, ReplyKind,
  FollowUpPrompt, JourneyRecord, ReminderItem, RuntimeContext, SlotName, UserProfile
} from '../core/AgentTypes';
import { eventBus } from '../core/EventBus';
import { CentralAgent } from '../agents/CentralAgent';
import { ContextStore } from '../core/ContextStore';
import { JourneyStore } from '../core/JourneyStore';
import { AppBootstrap, ROUTE_KEY } from '../core/AppBootstrap';
import { DateUtil } from '../core/DateUtil';
import { DeviceSyncService } from '../services/DeviceSyncService';
import { OcrCaptureService, OcrOutcome } from '../services/OcrCaptureService';
import { SpeechInputService } from '../services/SpeechInputService';
import { RuntimeContextService } from '../services/RuntimeContextService';
import { BackendConfig } from '../config/BackendConfig';
import { PermissionHelper } from '../utils/PermissionHelper';
import { UiLabels } from '../utils/UiLabels';
import { CardDataStore } from '../widget/CardDataStore';

/** 气泡下方的快捷按钮动作 */
class ChatAction {
  static readonly NONE: string = '';
  static readonly VIEW_JOURNEY: string = 'VIEW_JOURNEY';
  static readonly CALL_120: string = 'CALL_120';
  static readonly CALL_FAMILY: string = 'CALL_FAMILY';
  static readonly CAPTURE: string = 'CAPTURE';
  static readonly MANUAL_RECORD: string = 'MANUAL_RECORD';
  static readonly MIC_SETTINGS: string = 'MIC_SETTINGS';
  static readonly OPEN_PROFILE: string = 'OPEN_PROFILE';
}

/** 对话气泡 */
class ChatItem {
  id: number = 0;
  role: string = 'assistant';   // user / assistant
  text: string = '';
  action: string = '';
  actionLabel: string = '';
  action2: string = '';
  actionLabel2: string = '';

  constructor(id: number, role: string, text: string) {
    this.id = id;
    this.role = role;
    this.text = text;
  }
}

/** 进度条目 */
class ProgressItem {
  taskId: string = '';
  title: string = '';
  status: string = 'PENDING';
  dataSource: string = '';

  constructor(taskId: string, title: string, status: string, dataSource: string) {
    this.taskId = taskId;
    this.title = title;
    this.status = status;
    this.dataSource = dataSource;
  }
}

/** 页面注册的总线监听，供 aboutToDisappear 精确解绑 */
interface BoundHandler {
  event: BusEvent;
  handler: (msg: BusMessage) => void;
}

/** 本次启动内只问候一次 */
class SessionFlags {
  static greeted: boolean = false;
  static followUpSnoozed: boolean = false;
}

const DEFAULT_CHIPS: string[] = ['我要去市第一人民医院拿高血压药', '明天上午去复查血压', '下周三去看眼科'];

@Entry
@Component
struct Index {
  @State chats: ChatItem[] = [];
  @State progress: ProgressItem[] = [];
  @State progressTitle: string = '正在为您安排';
  @State progressDone: boolean = false;
  @State inputText: string = '';
  @State listening: boolean = false;
  @State partialText: string = '';
  @State busy: boolean = false;
  @State busyText: string = '';
  @State chips: string[] = DEFAULT_CHIPS;
  @State pendingRecord: ServiceRecord | null = null;
  @State followUpText: string = '';
  @State postVisitText: string = '';
  @State journeyStrip: string = '';
  @State journeyStripAction: string = '';
  @State modeLabel: string = '';
  @StorageLink('pendingRoute') @Watch('onRouteChanged') pendingRoute: string = '';

  private scroller: Scroller = new Scroller();
  private boundHandlers: BoundHandler[] = [];
  private chatSeq: number = 0;
  private followUp: FollowUpPrompt | null = null;
  private ready: boolean = false;

  aboutToAppear(): void {
    this.bind(BusEvent.SPEAK, (msg: BusMessage) => {
      const text: string = Index.textOf(msg.payload);
      if (text.length > 0) {
        this.pushAssistant(text);
      }
    });
    this.bind(BusEvent.PLAN_UPDATED, (msg: BusMessage) => {
      this.onPlanUpdated(msg.payload);
    });
    this.bind(BusEvent.TASK_FINISHED, (msg: BusMessage) => {
      this.onTaskFinished(msg.payload);
    });
    this.bind(BusEvent.PLAN_FINISHED, (msg: BusMessage) => {
      this.onPlanFinished(msg.payload);
    });
    this.bind(BusEvent.JOURNEY_CHANGED, (msg: BusMessage) => {
      this.refreshJourneyState();
    });

    AppBootstrap.ready().then(() => {
      this.ready = true;
      this.modeLabel = BackendConfig.enabled() ? '已连接大模型 · 说一句话我来安排' : '离线演示模式 · 说一句话我来安排';
      this.refreshAll();
      this.greetOnce();
      this.consumeRoute();
    }).catch((e: Error) => {
      console.error(`[Index] bootstrap wait failed: ${e.message}`);
    });
  }

  onPageShow(): void {
    if (this.ready) {
      this.refreshAll();
      this.consumeRoute();
    }
  }

  aboutToDisappear(): void {
    for (let i = 0; i < this.boundHandlers.length; i++) {
      eventBus.off(this.boundHandlers[i].event, this.boundHandlers[i].handler);
    }
    this.boundHandlers = [];
    SpeechInputService.cancel();
  }

  private bind(event: BusEvent, handler: (msg: BusMessage) => void): void {
    eventBus.on(event, handler);
    this.boundHandlers.push({ event: event, handler: handler });
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

  // ==================== 导航与系统能力 ====================

  private hostContext(): common.UIAbilityContext | null {
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    return ctx === undefined ? null : ctx as common.UIAbilityContext;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (e) {
      console.warn(`[Index] toast failed: ${e}`);
    }
  }

  private openPage(url: string, params: Record<string, Object> | null): void {
    const options: router.RouterOptions = params !== null ? { url: url, params: params } : { url: url };
    this.getUIContext().getRouter().pushUrl(options).catch((err: Error) => {
      console.error(`[Index] open ${url} failed: ${err.message}`);
    });
  }

  /** @Watch：从提醒通知或桌面卡片进入时跳到对应页面 */
  onRouteChanged(propName: string): void {
    if (this.ready) {
      this.consumeRoute();
    }
  }

  private consumeRoute(): void {
    const raw: string = this.pendingRoute;
    if (raw.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(ROUTE_KEY, '');
    const target: string = raw.split('#')[0];
    const store: JourneyStore = JourneyStore.getInstance();
    if (target === 'journey' && store.getForDisplay() !== null) {
      this.openPage('pages/JourneyPage', null);
    } else if (target === 'nav' && (store.getActive() !== null || store.getDraft() !== null)) {
      this.openPage('pages/NavGuidePage', null);
    }
  }

  private makeCall(phone: string): void {
    call.makeCall(phone).catch((err: Error) => {
      console.error(`[Index] makeCall failed: ${err.message}`);
      this.toast(`没能拨出，请直接拨打 ${phone}`);
    });
  }

  // ==================== 状态刷新 ====================

  private refreshAll(): void {
    this.refreshJourneyState();
    this.refreshFollowUp();
    this.refreshChips();
  }

  private refreshJourneyState(): void {
    const now: number = Date.now();
    const store: JourneyStore = JourneyStore.getInstance();
    const draft: JourneyRecord | null = store.getDraft();
    const active: JourneyRecord | null = store.getActive();
    if (draft !== null) {
      const a = draft.appointment;
      this.journeyStrip = `新方案待确认：${DateUtil.friendlyDate(a.visitDate, now)} ${a.visitTime} ${a.department}`;
      this.journeyStripAction = '去确认';
    } else if (active !== null) {
      const next: ReminderItem | null = Index.nextReminder(active, now);
      const a = active.appointment;
      this.journeyStrip = next !== null
        ? `下一步：${DateUtil.friendlyTime(next.triggerAt, now)} ${next.title}`
        : `${DateUtil.friendlyDate(a.visitDate, now)} ${a.visitTime} ${a.hospitalName}${a.department}`;
      this.journeyStripAction = '查看';
    } else {
      this.journeyStrip = '';
      this.journeyStripAction = '';
    }

    const post: JourneyRecord | null = store.needsPostVisitCheck(now);
    if (post !== null) {
      const a = post.appointment;
      this.postVisitText = `${DateUtil.friendlyDate(a.visitDate, now)}在${a.hospitalName}${a.department}看完了吗？` +
        '医生让您多久后复查？点一下我帮您记着。';
    } else {
      this.postVisitText = '';
    }
  }

  private static nextReminder(j: JourneyRecord, now: number): ReminderItem | null {
    let found: ReminderItem | null = null;
    for (let i = 0; i < j.reminders.length; i++) {
      const r: ReminderItem = j.reminders[i];
      if (r.triggerAt > now && (found === null || r.triggerAt < found.triggerAt)) {
        found = r;
      }
    }
    return found;
  }

  private refreshFollowUp(): void {
    if (SessionFlags.followUpSnoozed) {
      this.followUp = null;
      this.followUpText = '';
      return;
    }
    const now: number = Date.now();
    const prompt: FollowUpPrompt | null = CentralAgent.getInstance().proactiveCheck(now);
    this.followUp = prompt;
    this.followUpText = prompt !== null ? prompt.text : '';
    if (prompt !== null) {
      const store: ContextStore = ContextStore.getInstance();
      if (!store.wasPromptedToday(prompt.recordId, now)) {
        DeviceSyncService.speak(prompt.text, false);
        store.markFollowUpPrompted(prompt.recordId, now).catch((e: Error) => {
          console.warn(`[Index] mark prompted failed: ${e.message}`);
        });
      }
    }
  }

  /** 快捷回答：正在追问什么就给什么选项；有行程时给常见问题 */
  private refreshChips(): void {
    const slot: string = CentralAgent.getInstance().getPendingSlot();
    if (slot === SlotName.HOSPITAL) {
      const list: string[] = [];
      const preferred: string[] = ContextStore.getInstance().getProfile().preferredHospitals;
      for (let i = 0; i < preferred.length && list.length < 2; i++) {
        list.push(preferred[i]);
      }
      const extras: string[] = ['市第一人民医院', '市中医院', '社区卫生服务中心'];
      for (let i = 0; i < extras.length && list.length < 3; i++) {
        if (list.indexOf(extras[i]) < 0) {
          list.push(extras[i]);
        }
      }
      this.chips = list;
    } else if (slot === SlotName.DEPARTMENT) {
      this.chips = ['心血管内科', '内分泌科', '眼科', '骨科'];
    } else if (slot === SlotName.DATE) {
      this.chips = ['明天上午', '后天上午', '下周一上午'];
    } else if (JourneyStore.getInstance().getForDisplay() !== null) {
      this.chips = ['我几点出发？', '诊室在几楼？', '要带什么？'];
    } else {
      this.chips = DEFAULT_CHIPS;
    }
  }

  private greetOnce(): void {
    if (SessionFlags.greeted) {
      return;
    }
    SessionFlags.greeted = true;
    const profile: UserProfile = ContextStore.getInstance().getProfile();
    const name: string = profile.name.length > 0 ? `${profile.name.substring(0, 1)}阿姨/叔叔` : '您';
    const greeting: string = profile.name.length > 0 ? `${name}好` : '您好';
    this.pushAssistant(`${greeting}！我是您的陪诊助手。想去医院看病、拿药，直接跟我说就行，比如“明天去市第一人民医院复查血压”。`);
  }

  // ==================== 对话 ====================

  private pushUser(text: string): void {
    this.chatSeq += 1;
    this.chats.push(new ChatItem(this.chatSeq, 'user', text));
    this.scrollToBottom();
  }

  private pushAssistant(text: string): ChatItem {
    this.chatSeq += 1;
    const item: ChatItem = new ChatItem(this.chatSeq, 'assistant', text);
    this.chats.push(item);
    this.scrollToBottom();
    return item;
  }

  private pushAssistantWithActions(text: string, action: string, label: string, action2: string, label2: string): void {
    this.chatSeq += 1;
    const item: ChatItem = new ChatItem(this.chatSeq, 'assistant', text);
    item.action = action;
    item.actionLabel = label;
    item.action2 = action2;
    item.actionLabel2 = label2;
    this.chats.push(item);
    this.scrollToBottom();
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 120);
  }

  private async submit(raw: string): Promise<void> {
    const text: string = raw.trim();
    if (text.length === 0 || this.busy) {
      return;
    }
    DeviceSyncService.stopSpeaking();
    this.pushUser(text);
    this.inputText = '';
    this.busy = true;
    this.busyText = '正在理解您的需求…';
    try {
      const rt: RuntimeContext = await RuntimeContextService.build(this.hostContext(), true);
      const reply: AgentReply = await CentralAgent.getInstance().handleUserRequest(text, rt);
      this.handleReply(reply);
    } catch (e) {
      console.error(`[Index] submit failed: ${e}`);
      this.pushAssistant('刚才出了点问题，请再说一次试试。');
    } finally {
      this.busy = false;
      this.busyText = '';
      this.refreshChips();
      this.refreshJourneyState();
    }
  }

  private handleReply(reply: AgentReply): void {
    if (reply.kind === ReplyKind.NONE || reply.text.length === 0) {
      return;
    }
    const contact: string = ContextStore.getInstance().getProfile().emergencyContact;
    if (reply.kind === ReplyKind.EMERGENCY) {
      this.pushAssistantWithActions(reply.text, ChatAction.CALL_120, '拨打 120',
        contact.length > 0 ? ChatAction.CALL_FAMILY : ChatAction.NONE, contact.length > 0 ? '打给家人' : '');
    } else if (reply.kind === ReplyKind.CALL_FAMILY) {
      if (contact.length > 0) {
        this.pushAssistantWithActions(reply.text, ChatAction.CALL_FAMILY, `拨打 ${contact}`, ChatAction.NONE, '');
        this.makeCall(contact);
      } else {
        this.pushAssistantWithActions('还没有设置家人的电话，可以在“我的”里填写紧急联系人。', ChatAction.OPEN_PROFILE,
          '去填写', ChatAction.NONE, '');
        DeviceSyncService.speak('还没有设置家人的电话，可以在“我的”里填写。', true);
        return;
      }
    } else if (reply.kind === ReplyKind.REPORT_GUIDE) {
      this.pushAssistantWithActions(reply.text, ChatAction.CAPTURE, '拍报告单', ChatAction.NONE, '');
    } else if (reply.kind === ReplyKind.PLAN_DONE || reply.kind === ReplyKind.PLAN_PARTIAL) {
      this.pushAssistantWithActions(reply.text, ChatAction.VIEW_JOURNEY, '查看完整安排并确认', ChatAction.NONE, '');
    } else {
      this.pushAssistant(reply.text);
    }
    DeviceSyncService.speak(reply.text, false);
  }

  private onChatAction(action: string): void {
    if (action === ChatAction.VIEW_JOURNEY) {
      this.openPage('pages/JourneyPage', null);
    } else if (action === ChatAction.CALL_120) {
      this.makeCall('120');
    } else if (action === ChatAction.CALL_FAMILY) {
      const contact: string = ContextStore.getInstance().getProfile().emergencyContact;
      if (contact.length > 0) {
        this.makeCall(contact);
      }
    } else if (action === ChatAction.CAPTURE) {
      this.onCapturePhoto();
    } else if (action === ChatAction.MANUAL_RECORD) {
      const params: Record<string, Object> = { 'mode': 'addRecord' };
      this.openPage('pages/ProfilePage', params);
    } else if (action === ChatAction.OPEN_PROFILE) {
      this.openPage('pages/ProfilePage', null);
    } else if (action === ChatAction.MIC_SETTINGS) {
      const ctx: common.UIAbilityContext | null = this.hostContext();
      if (ctx !== null) {
        PermissionHelper.openSettingDialog(ctx, ['ohos.permission.MICROPHONE']).then((granted: boolean) => {
          this.toast(granted ? '麦克风已开启，再点一下说话吧' : '还没有开启麦克风，可以先打字');
        });
      }
    }
  }

  // ==================== 语音输入 ====================

  private async onMicTap(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.listening) {
      SpeechInputService.finish();
      return;
    }
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx === null) {
      return;
    }
    const granted: boolean = await PermissionHelper.request(ctx, ['ohos.permission.MICROPHONE'],
      'ohos.permission.MICROPHONE', false);
    if (!granted) {
      this.pushAssistantWithActions('没有麦克风权限，我听不到您说话。可以点下面去开启，也可以直接打字。',
        ChatAction.MIC_SETTINGS, '去开启麦克风', ChatAction.NONE, '');
      return;
    }
    DeviceSyncService.stopSpeaking();
    this.listening = true;
    this.partialText = '';
    try {
      const text: string = await SpeechInputService.start((t: string) => {
        this.partialText = t;
      });
      this.listening = false;
      this.partialText = '';
      if (text.trim().length === 0) {
        this.toast('没听清，请再说一次，或者打字告诉我');
        return;
      }
      await this.submit(text);
    } catch (e) {
      this.listening = false;
      this.partialText = '';
      const code: string = (e as Error).message;
      if (code === 'ENGINE_UNAVAILABLE') {
        this.pushAssistant('这台设备暂时用不了语音识别（模拟器上常见）。您可以打字，或者点下面的例句试试。');
      } else if (code !== 'BUSY') {
        this.toast('语音识别出错了，请再试一次');
      }
    }
  }

  // ==================== 拍照录入病历 ====================

  private async onCapturePhoto(): Promise<void> {
    if (this.busy) {
      return;
    }
    let uri: string = '';
    try {
      uri = await OcrCaptureService.pickPhoto();
    } catch (e) {
      console.error(`[Index] pick photo failed: ${e}`);
      this.toast('打不开相册，请稍后再试');
      return;
    }
    if (uri.length === 0) {
      return;
    }
    this.busy = true;
    this.busyText = '正在识别病历…';
    try {
      const outcome: OcrOutcome = await OcrCaptureService.captureFromUri(uri);
      if (outcome.record !== null) {
        this.pendingRecord = outcome.record;
        this.pushAssistant('识别出来了，麻烦您在上面核对一下，没问题就点“确认无误”。');
        DeviceSyncService.speak('识别出来了，麻烦您核对一下。', true);
        this.scroller.scrollEdge(Edge.Top);
      } else if (outcome.reason === 'OCR_UNAVAILABLE') {
        this.pushAssistantWithActions('这台设备暂时用不了文字识别（模拟器上常见），可以改成手动录入。',
          ChatAction.MANUAL_RECORD, '手动录入', ChatAction.NONE, '');
      } else if (outcome.reason === 'NO_TEXT') {
        this.pushAssistantWithActions('照片里没认出文字，可能拍糊了。请在光线好的地方把单子放平再拍一次。',
          ChatAction.CAPTURE, '重新拍', ChatAction.MANUAL_RECORD, '手动录入');
      } else if (outcome.reason === 'LOAD_FAILED') {
        this.toast('照片打不开，请换一张试试');
      } else {
        this.pushAssistantWithActions('这张好像不是处方单或病历，没找到医院和用药信息。',
          ChatAction.CAPTURE, '重新拍', ChatAction.MANUAL_RECORD, '手动录入');
      }
    } finally {
      this.busy = false;
      this.busyText = '';
    }
  }

  private async onConfirmPendingRecord(): Promise<void> {
    const r: ServiceRecord | null = this.pendingRecord;
    if (r === null) {
      return;
    }
    const record: ServiceRecord = {
      recordId: r.recordId,
      hospital: r.hospital,
      department: r.department,
      doctorName: r.doctorName,
      visitDate: r.visitDate.length > 0 ? r.visitDate : DateUtil.todayStr(Date.now()),
      followUpDays: r.followUpDays,
      prescription: r.prescription,
      source: RecordSource.OCR_SCAN,
      confirmed: true
    };
    await ContextStore.getInstance().addRecord(record);
    this.pendingRecord = null;
    // 如果正等着记录这次就诊的结果，拍了处方单就算记录完成
    if (JourneyStore.getInstance().needsPostVisitCheck(Date.now()) !== null) {
      await this.finishActiveJourney();
    }
    const text: string = record.followUpDays > 0
      ? `记好了。医生让您${UiLabels.followUp(record.followUpDays)}，快到时间我会提前提醒您。`
      : '记好了，这条病历已经存在您手机上。';
    this.pushAssistant(text);
    DeviceSyncService.speak(text, true);
    this.refreshAll();
  }

  private onDiscardPendingRecord(): void {
    this.pendingRecord = null;
    this.toast('已丢弃，没有保存');
  }

  // ==================== 主动服务卡片 ====================

  private onFollowUpAccept(): void {
    const p: FollowUpPrompt | null = this.followUp;
    if (p === null) {
      return;
    }
    this.followUp = null;
    this.followUpText = '';
    this.submit(CentralAgent.buildFollowUpRequest(p, Date.now()));
  }

  private onFollowUpLater(): void {
    SessionFlags.followUpSnoozed = true;
    this.followUp = null;
    this.followUpText = '';
    this.toast('好的，下次打开再提醒您');
  }

  private async onFollowUpDismiss(): Promise<void> {
    const p: FollowUpPrompt | null = this.followUp;
    if (p === null) {
      return;
    }
    await ContextStore.getInstance().dismissFollowUp(p.recordId);
    this.followUp = null;
    this.followUpText = '';
    this.toast('好的，这次复诊不再提醒');
  }

  /** 看完病：记录医生说的复诊间隔 */
  private async onPostVisitRecord(days: number): Promise<void> {
    const j: JourneyRecord | null = JourneyStore.getInstance().getActive();
    if (j === null) {
      return;
    }
    const a = j.appointment;
    const record: ServiceRecord = {
      recordId: `visit_${j.journeyId}`,
      hospital: a.hospitalName,
      department: a.department,
      doctorName: a.doctorName,
      visitDate: a.visitDate,
      followUpDays: days,
      prescription: '',
      source: RecordSource.POST_VISIT_ASK,
      confirmed: true
    };
    await ContextStore.getInstance().addRecord(record);
    await this.finishActiveJourney();
    const text: string = days > 0
      ? `记好了，${UiLabels.followUp(days)}。快到时间我会提前问您要不要安排。拿到的处方单也可以拍一下给我。`
      : '记好了，这次不用复诊。有需要随时叫我。';
    this.pushAssistantWithActions(text, days > 0 ? ChatAction.CAPTURE : ChatAction.NONE, days > 0 ? '拍处方单' : '',
      ChatAction.NONE, '');
    DeviceSyncService.speak(text, true);
    this.refreshAll();
  }

  private async onPostVisitMissed(): Promise<void> {
    await JourneyStore.getInstance().cancelActive();
    await DeviceSyncService.cancelAllReminders();
    await this.writeEmptyCard();
    const text: string = '好的，这次没去成也没关系。想重新安排的话，跟我说哪天去就行。';
    this.pushAssistant(text);
    DeviceSyncService.speak(text, true);
    this.refreshAll();
  }

  private async finishActiveJourney(): Promise<void> {
    await JourneyStore.getInstance().completeActive();
    await DeviceSyncService.cancelAllReminders();
    await this.writeEmptyCard();
  }

  private async writeEmptyCard(): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx !== null) {
      await CardDataStore.writeSnapshot(ctx, CardDataStore.emptySnapshot());
    }
  }

  // ==================== 进度面板 ====================

  private onPlanUpdated(payload: string): void {
    try {
      const plan: TaskPlan = JSON.parse(payload) as TaskPlan;
      const list: ProgressItem[] = [];
      let finished: boolean = true;
      for (let i = 0; i < plan.nodes.length; i++) {
        const n = plan.nodes[i];
        const old: ProgressItem | undefined = this.progress.find((p: ProgressItem) => p.taskId === n.id);
        const keepSource: boolean = old !== undefined && n.status === 'SUCCESS';
        list.push(new ProgressItem(n.id, n.title, n.status as string, keepSource ? (old as ProgressItem).dataSource : ''));
        if (n.status === 'PENDING' || n.status === 'RUNNING') {
          finished = false;
        }
      }
      this.progress = list;
      if (!finished) {
        this.progressDone = false;
        this.progressTitle = plan.version > 1 ? '情况有变，正在重新安排' : '正在为您安排';
        this.busyText = '正在为您安排…';
      }
    } catch (e) {
      console.error(`[Index] plan parse error: ${e}`);
    }
  }

  private onTaskFinished(payload: string): void {
    try {
      const r: AgentResult = JSON.parse(payload) as AgentResult;
      const list: ProgressItem[] = [];
      for (let i = 0; i < this.progress.length; i++) {
        const p: ProgressItem = this.progress[i];
        if (p.taskId === r.taskId) {
          list.push(new ProgressItem(p.taskId, p.title, r.success ? 'SUCCESS' : 'FAILED',
            r.success ? r.dataSource as string : ''));
        } else {
          list.push(p);
        }
      }
      this.progress = list;
    } catch (e) {
      console.error(`[Index] result parse error: ${e}`);
    }
  }

  private onPlanFinished(payload: string): void {
    let partial: boolean = false;
    try {
      const obj: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      partial = obj['partial'] === true;
    } catch (e) {
      partial = false;
    }
    this.progressDone = true;
    this.progressTitle = partial ? '部分安排已完成' : '已为您安排好';
    this.refreshJourneyState();
  }

  // ==================== UI ====================

  @Builder
  ChatBubble(item: ChatItem) {
    Column() {
      Row() {
        if (item.role === 'user') {
          Blank()
          Text(item.text)
            .fontSize(20)
            .fontColor('#FFFFFF')
            .lineHeight(30)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor('#2E6F8E')
            .borderRadius(18)
            .constraintSize({ maxWidth: '80%' })
        } else {
          Image($r('app.media.agent_avatar'))
            .width(36)
            .height(36)
            .borderRadius(18)
            .margin({ right: 8 })
          Text(item.text)
            .fontSize(20)
            .fontColor('#22303C')
            .lineHeight(31)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor('#FFFFFF')
            .borderRadius(18)
            .constraintSize({ maxWidth: '80%' })
            .onClick(() => {
              DeviceSyncService.speak(item.text, true);
            })
          Blank()
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (item.role === 'assistant' && item.action.length > 0) {
        Row() {
          Button(item.actionLabel, { type: ButtonType.Capsule })
            .fontSize(18)
            .height(46)
            .fontColor('#FFFFFF')
            .backgroundColor(item.action === ChatAction.CALL_120 ? '#C8553D' : '#2E6F8E')
            .onClick(() => {
              this.onChatAction(item.action);
            })
          if (item.action2.length > 0) {
            Button(item.actionLabel2, { type: ButtonType.Capsule })
              .fontSize(18)
              .height(46)
              .fontColor('#2E6F8E')
              .backgroundColor('#E3EEF4')
              .margin({ left: 10 })
              .onClick(() => {
                this.onChatAction(item.action2);
              })
          }
        }
        .width('100%')
        .padding({ left: 44 })
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .margin({ bottom: 14 })
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor('#7A8A96')
        .width(70)
      Text(value.length > 0 ? value : '没认出来，可稍后补充')
        .fontSize(16)
        .fontColor(value.length > 0 ? '#22303C' : '#B0BAC2')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  @Builder
  ProgressRow(item: ProgressItem) {
    Row() {
      Text(UiLabels.taskIcon(item.status))
        .fontSize(20)
        .width(32)
        .fontColor(item.status === 'FAILED' ? '#C8553D' : '#2E6F8E')
      Text(item.title)
        .fontSize(18)
        .fontColor(item.status === 'SUCCESS' ? '#3B7A57' : '#4A5A66')
        .layoutWeight(1)
      if (item.dataSource.length > 0 && UiLabels.source(item.dataSource).length > 0) {
        Text(UiLabels.source(item.dataSource))
          .fontSize(12)
          .fontColor(UiLabels.sourceColor(item.dataSource))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor('#F4F1EC')
          .margin({ right: 8 })
      }
      Text(UiLabels.taskStatus(item.status))
        .fontSize(15)
        .fontColor('#8A9AA6')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  CardShell(title: string, color: string) {
    Text(title)
      .fontSize(18)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .width('100%')
      .margin({ bottom: 8 })
  }

  @Builder
  SmallButton(label: string, primary: boolean, handler: () => void) {
    Button(label, { type: ButtonType.Capsule })
      .fontSize(17)
      .height(44)
      .fontColor(primary ? '#FFFFFF' : '#2E6F8E')
      .backgroundColor(primary ? '#2E6F8E' : '#E3EEF4')
      .margin({ right: 10, top: 8 })
      .onClick(() => {
        handler();
      })
  }

  build() {
    Column() {
      // 顶部
      Row() {
        Image($r('app.media.agent_avatar'))
          .width(48)
          .height(48)
          .borderRadius(24)
        Column() {
          Text('智护同行')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2A34')
          Text(this.modeLabel)
            .fontSize(13)
            .fontColor('#7A8A96')
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
        Button('拍病历', { type: ButtonType.Capsule })
          .fontSize(16)
          .height(40)
          .fontColor('#2E6F8E')
          .backgroundColor('#E3EEF4')
          .onClick(() => {
            this.onCapturePhoto();
          })
        Button('我的', { type: ButtonType.Capsule })
          .fontSize(16)
          .height(40)
          .fontColor('#2E6F8E')
          .backgroundColor('#E3EEF4')
          .margin({ left: 8 })
          .onClick(() => {
            this.openPage('pages/ProfilePage', null);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Scroll(this.scroller) {
        Column() {
          // 当前行程
          if (this.journeyStrip.length > 0) {
            Row() {
              Text(this.journeyStrip)
                .fontSize(17)
                .fontColor('#1B2A34')
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Button(this.journeyStripAction, { type: ButtonType.Capsule })
                .fontSize(16)
                .height(40)
                .backgroundColor('#2E6F8E')
                .margin({ left: 8 })
                .onClick(() => {
                  this.openPage('pages/JourneyPage', null);
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor('#E3EEF4')
            .borderRadius(14)
            .margin({ bottom: 12 })
          }

          // 主动复诊提醒
          if (this.followUpText.length > 0) {
            Column() {
              this.CardShell('复诊时间快到了', '#A65A2E')
              Text(this.followUpText)
                .fontSize(18)
                .fontColor('#22303C')
                .lineHeight(28)
                .width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                this.SmallButton('帮我安排', true, () => {
                  this.onFollowUpAccept();
                })
                this.SmallButton('以后再说', false, () => {
                  this.onFollowUpLater();
                })
                this.SmallButton('不用复诊了', false, () => {
                  this.onFollowUpDismiss();
                })
              }
              .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFF6EC')
            .borderRadius(16)
            .margin({ bottom: 12 })
          }

          // 看完病：记录复诊时间
          if (this.postVisitText.length > 0) {
            Column() {
              this.CardShell('看完病了吗？', '#3B7A57')
              Text(this.postVisitText)
                .fontSize(18)
                .fontColor('#22303C')
                .lineHeight(28)
                .width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                this.SmallButton('2周后复查', true, () => {
                  this.onPostVisitRecord(14);
                })
                this.SmallButton('1个月后', true, () => {
                  this.onPostVisitRecord(30);
                })
                this.SmallButton('3个月后', true, () => {
                  this.onPostVisitRecord(90);
                })
                this.SmallButton('不用复诊', false, () => {
                  this.onPostVisitRecord(0);
                })
                this.SmallButton('拍处方单', false, () => {
                  this.onCapturePhoto();
                })
                this.SmallButton('没去成', false, () => {
                  this.onPostVisitMissed();
                })
              }
              .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#EEF7F1')
            .borderRadius(16)
            .margin({ bottom: 12 })
          }

          // 拍照识别待确认 —— 识别结果不直接生效，必须用户确认
          if (this.pendingRecord !== null) {
            Column() {
              this.CardShell('识别到一条病历，麻烦您看看对不对', '#1B2A34')
              this.InfoRow('医院', this.pendingRecord.hospital)
              this.InfoRow('科室', this.pendingRecord.department)
              this.InfoRow('医生', this.pendingRecord.doctorName)
              this.InfoRow('日期', this.pendingRecord.visitDate)
              this.InfoRow('复诊', this.pendingRecord.followUpDays > 0 ?
                UiLabels.followUp(this.pendingRecord.followUpDays) : '')
              this.InfoRow('用药', this.pendingRecord.prescription)
              Row() {
                Button('不对，丢掉', { type: ButtonType.Capsule })
                  .fontSize(17)
                  .height(46)
                  .fontColor('#7A8A96')
                  .backgroundColor('#EEF3F6')
                  .layoutWeight(1)
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.onDiscardPendingRecord();
                  })
                Button('确认无误', { type: ButtonType.Capsule })
                  .fontSize(17)
                  .height(46)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#2E6F8E')
                  .layoutWeight(1)
                  .onClick(() => {
                    this.onConfirmPendingRecord();
                  })
              }
              .width('100%')
              .margin({ top: 10 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
            .margin({ bottom: 12 })
          }

          // 进度面板：看得见 Agent 正在替我做什么
          if (this.progress.length > 0) {
            Column() {
              Row() {
                Text(this.progressTitle)
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#5A6A76')
                  .layoutWeight(1)
                if (this.progressDone) {
                  Text('收起')
                    .fontSize(15)
                    .fontColor('#8A9AA6')
                    .padding(6)
                    .onClick(() => {
                      this.progress = [];
                    })
                }
              }
              .width('100%')
              ForEach(this.progress, (item: ProgressItem) => {
                this.ProgressRow(item);
              }, (item: ProgressItem) => `${item.taskId}_${item.status}_${item.dataSource}`)
              if (this.progressDone) {
                Button('查看完整安排', { type: ButtonType.Capsule })
                  .fontSize(18)
                  .height(46)
                  .width('100%')
                  .backgroundColor('#2E6F8E')
                  .margin({ top: 8 })
                  .onClick(() => {
                    this.openPage('pages/JourneyPage', null);
                  })
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
            .margin({ bottom: 14 })
          }

          ForEach(this.chats, (item: ChatItem) => {
            this.ChatBubble(item);
          }, (item: ChatItem) => `${item.id}`)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 4, bottom: 8 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // 底部输入区
      Column() {
        if (this.busy) {
          Row() {
            LoadingProgress()
              .width(26)
              .height(26)
              .color('#2E6F8E')
            Text(this.busyText.length > 0 ? this.busyText : '请稍等…')
              .fontSize(16)
              .fontColor('#5A6A76')
              .margin({ left: 6 })
          }
          .margin({ bottom: 8 })
        }
        if (this.listening) {
          Text(this.partialText.length > 0 ? this.partialText : '我在听，请说…')
            .fontSize(20)
            .fontColor('#1B2A34')
            .width('100%')
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .margin({ bottom: 8 })
        } else if (!this.busy) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.chips, (chip: string) => {
                Text(chip)
                  .fontSize(16)
                  .fontColor('#2E6F8E')
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .backgroundColor('#FFFFFF')
                  .borderRadius(18)
                  .border({ width: 1, color: '#C9DCE6' })
                  .onClick(() => {
                    this.submit(chip);
                  })
              }, (chip: string) => chip)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .margin({ bottom: 8 })
        }

        Row() {
          TextInput({ text: this.inputText, placeholder: '也可以打字告诉我' })
            .fontSize(18)
            .height(50)
            .layoutWeight(1)
            .backgroundColor('#FFFFFF')
            .borderRadius(25)
            .enterKeyType(EnterKeyType.Send)
            .enabled(!this.busy)
            .onChange((v: string) => {
              this.inputText = v;
            })
            .onSubmit((enterKey: EnterKeyType) => {
              this.submit(this.inputText);
            })
          Button('发送', { type: ButtonType.Capsule })
            .fontSize(18)
            .height(50)
            .margin({ left: 8 })
            .backgroundColor(this.busy ? '#9FB5C1' : '#2E6F8E')
            .enabled(!this.busy)
            .onClick(() => {
              this.submit(this.inputText);
            })
        }
        .width('100%')

        Button(this.listening ? '说完了，点我结束' : (this.busy ? '正在安排…' : '点我说话'),
          { type: ButtonType.Capsule })
          .width('100%')
          .height(64)
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(this.listening ? '#C8553D' : (this.busy ? '#9FB5C1' : '#2E6F8E'))
          .margin({ top: 10 })
          .enabled(!this.busy)
          .onClick(() => {
            this.onMicTap();
          })
        Text(this.listening ? '说完停一下会自动结束' : '点一下，说出您的需求')
          .fontSize(13)
          .fontColor('#8A9AA6')
          .margin({ top: 4 })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 14 })
      .backgroundColor('#EAF0F3')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F6F8')
  }
}
