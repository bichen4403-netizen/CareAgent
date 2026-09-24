/**
 * 智护同行 - 中枢 Agent（总调度）
 *
 * 职责：
 *   1. 先处理不需要规划的话：紧急情况、取消、联系家人、询问已有安排
 *   2. 调用 IntentParser 理解需求，信息不全就追问（记住追问的是哪一项）
 *   3. 调用 TaskPlanner 拆成 DAG，按依赖分批并行调度四个执行 Agent
 *   4. 每批执行后检测异常（医生停诊 / 恶劣天气），局部重规划后继续，最多 2 次
 *   5. 汇总为 JourneyRecord 写入端侧，页面据此展示并引导用户去官方渠道确认
 */

import {
  ParsedIntent, IntentType, TaskPlan, TaskNode, TaskStatus, TaskType, RuntimeContext, AgentResult,
  BusEvent, Anomaly, AnomalyType, AgentReply, ReplyKind, JourneyRecord, JourneyStage, Appointment,
  MedicalPreparation, TravelPlan, IndoorNavPlan, ReminderItem, DataSourceType, FollowUpPrompt, SlotName,
  DemoSettings
} from '../core/AgentTypes';
import { eventBus, blackboard } from '../core/EventBus';
import { IntentParser } from '../core/IntentParser';
import { TaskPlanner } from '../core/TaskPlanner';
import { ContextStore } from '../core/ContextStore';
import { JourneyStore } from '../core/JourneyStore';
import { NluRules } from '../core/NluRules';
import { DateUtil } from '../core/DateUtil';
import { BaseAgent } from './BaseAgent';
import { MedicalAgent } from './MedicalAgent';
import { TravelAgent } from './TravelAgent';
import { NavigationAgent } from './NavigationAgent';
import { ReminderAgent } from './ReminderAgent';

const MAX_REPLANS: number = 2;
const MAX_CLARIFY_ROUNDS: number = 4;
/** 追问状态的有效期：老人走开 10 分钟后再说话，按新的请求理解，避免接上早已过时的追问 */
const PENDING_TTL_MS: number = 10 * 60 * 1000;

export class CentralAgent {
  private static instance: CentralAgent | null = null;
  private agents: Map<string, BaseAgent> = new Map<string, BaseAgent>();
  private running: boolean = false;
  private pendingIntent: ParsedIntent | null = null;
  private pendingAt: number = 0;
  private clarifyRounds: number = 0;
  private handledAnomalies: Set<string> = new Set<string>();

  private constructor() {
    this.agents.set(TaskType.MEDICAL as string, new MedicalAgent());
    this.agents.set(TaskType.TRAVEL as string, new TravelAgent());
    this.agents.set(TaskType.NAVIGATION as string, new NavigationAgent());
    this.agents.set(TaskType.REMINDER as string, new ReminderAgent());
  }

  static getInstance(): CentralAgent {
    if (CentralAgent.instance === null) {
      CentralAgent.instance = new CentralAgent();
    }
    return CentralAgent.instance;
  }

  isBusy(): boolean {
    return this.running;
  }

  /** 当前正在追问的槽位（页面据此给出快捷回答），没有返回空串 */
  getPendingSlot(): string {
    const p: ParsedIntent | null = this.pendingIntent;
    if (p === null || p.missingSlots.length === 0) {
      return '';
    }
    return p.missingSlots[0];
  }

  clearPending(): void {
    this.pendingIntent = null;
    this.clarifyRounds = 0;
    this.pendingAt = 0;
  }

  private setPending(intent: ParsedIntent, nowTs: number): void {
    this.pendingIntent = intent;
    this.pendingAt = nowTs;
  }

  /** 追问超过有效期未回答则作废（时间回拨时不作废） */
  private expireStalePending(nowTs: number): void {
    if (this.pendingIntent !== null && nowTs - this.pendingAt > PENDING_TTL_MS) {
      this.clearPending();
    }
  }

  private static reply(kind: ReplyKind, text: string): AgentReply {
    const r: AgentReply = { kind: kind, text: text };
    return r;
  }

  /** 中间过程的播报（例如“医生停诊，我重新调整一下”），页面会显示并朗读 */
  private static say(text: string): void {
    const payload: Record<string, Object> = { 'text': text };
    eventBus.emit(BusEvent.SPEAK, JSON.stringify(payload));
  }

  // ==================== 入口 ====================

  async handleUserRequest(userText: string, rt: RuntimeContext): Promise<AgentReply> {
    const text: string = userText.trim();
    if (text.length === 0) {
      return CentralAgent.reply(ReplyKind.NONE, '');
    }
    if (this.running) {
      return CentralAgent.reply(ReplyKind.BUSY, '我正在安排上一件事，请稍等一下。');
    }
    this.expireStalePending(rt.nowTs);

    if (NluRules.isEmergency(text)) {
      this.clearPending();
      return CentralAgent.reply(ReplyKind.EMERGENCY,
        '您说的情况可能很危险，请马上拨打 120 急救电话，或请身边的人帮忙。我不能代替医生判断。');
    }
    if (NluRules.isCallFamily(text)) {
      return CentralAgent.reply(ReplyKind.CALL_FAMILY, '好的，我帮您打给家里人。');
    }
    if (NluRules.isCancel(text)) {
      const hadPending: boolean = this.pendingIntent !== null;
      this.clearPending();
      if (!hadPending && NluRules.mentionsJourney(text) && JourneyStore.getInstance().getActive() !== null) {
        return CentralAgent.reply(ReplyKind.INFO,
          '已经确认的安排，请打开“陪诊安排”，点最下面的“取消这次安排”，我会把提醒一起关掉。');
      }
      return CentralAgent.reply(ReplyKind.CANCELLED,
        hadPending ? '好的，刚才的事先不办了。有需要随时叫我。' : '好的，有需要随时叫我。');
    }

    // 询问已有安排：直接从端侧行程回答，不走大模型
    if (this.pendingIntent === null) {
      const question: string = NluRules.journeyQuestion(text);
      if (question.length > 0) {
        const answer: string = this.answerJourneyQuestion(question, rt.nowTs);
        if (answer.length > 0) {
          return CentralAgent.reply(ReplyKind.INFO, answer);
        }
      }
    }

    const pending: ParsedIntent | null = this.pendingIntent;
    const intent: ParsedIntent = pending !== null
      ? await IntentParser.parseFollowUp(text, pending, rt)
      : await IntentParser.parse(text, rt);

    if (intent.type === IntentType.REPORT_QUERY) {
      this.clearPending();
      return CentralAgent.reply(ReplyKind.REPORT_GUIDE,
        '检查报告要在医院的官方渠道或自助机上查。报告单拿到手后，点“拍病历”拍一下，我帮您记下来。');
    }
    if (intent.type === IntentType.UNKNOWN) {
      return CentralAgent.reply(ReplyKind.CLARIFY,
        '我可以帮您安排看病、拿药。您可以这样说：“明天去市第一人民医院复查血压”。');
    }

    if (intent.missingSlots.length > 0) {
      this.clarifyRounds += 1;
      if (this.clarifyRounds > MAX_CLARIFY_ROUNDS) {
        this.clearPending();
        return CentralAgent.reply(ReplyKind.CLARIFY,
          '信息还不太全，我们换个说法吧，比如：“明天上午去市第一人民医院心血管内科复查”。');
      }
      this.setPending(intent, rt.nowTs);
      return CentralAgent.reply(ReplyKind.CLARIFY, IntentParser.buildClarifyQuestion(intent));
    }

    this.clearPending();
    this.running = true;
    try {
      return await this.runPlan(intent, rt);
    } catch (e) {
      console.error(`[CentralAgent] plan failed: ${e}`);
      return CentralAgent.reply(ReplyKind.ERROR, '安排的时候出了点问题，请再说一次试试。');
    } finally {
      this.running = false;
    }
  }

  // ==================== 调度 ====================

  private async runPlan(intent: ParsedIntent, rt: RuntimeContext): Promise<AgentReply> {
    blackboard.reset();
    this.handledAnomalies.clear();
    const plan: TaskPlan = TaskPlanner.plan(intent);
    blackboard.setPlan(plan);
    eventBus.emit(BusEvent.PLAN_UPDATED, JSON.stringify(plan));

    let replans: number = 0;
    let guard: number = 0;
    while (!TaskPlanner.isPlanFinished(plan) && guard < 12) {
      guard += 1;
      const runnable: TaskNode[] = TaskPlanner.getRunnableTasks(plan);
      if (runnable.length === 0) {
        break;   // 剩下的任务依赖失败，无法继续
      }
      const jobs: Promise<AgentResult>[] = [];
      for (let i = 0; i < runnable.length; i++) {
        const agent: BaseAgent | undefined = this.agents.get(runnable[i].type as string);
        if (agent === undefined) {
          runnable[i].status = TaskStatus.SKIPPED;
          continue;
        }
        jobs.push(agent.execute(runnable[i], rt));
      }
      await Promise.all(jobs);
      eventBus.emit(BusEvent.PLAN_UPDATED, JSON.stringify(plan));

      // 挂号环节缺信息或约不上：回到对话继续追问
      const t1: TaskNode | null = TaskPlanner.findNode(plan, 'T1');
      if (t1 !== null && t1.status === TaskStatus.FAILED) {
        CentralAgent.skipPending(plan);
        eventBus.emit(BusEvent.PLAN_UPDATED, JSON.stringify(plan));
        const r: AgentResult | undefined = blackboard.getResult('T1');
        const prefix: string = 'NEED_CLARIFICATION:';
        const slot: string = (r !== undefined && r.errorMsg.startsWith(prefix)) ? r.errorMsg.substring(prefix.length) : '';
        if (slot.length > 0) {
          this.setPending(CentralAgent.withMissing(intent, slot), rt.nowTs);
          this.clarifyRounds = 1;
          return CentralAgent.reply(ReplyKind.CLARIFY, r !== undefined ? r.speech : '');
        }
        return CentralAgent.reply(ReplyKind.ERROR,
          r !== undefined && r.speech.length > 0 ? r.speech : '挂号方案暂时生成不了，请稍后再试。');
      }

      if (replans < MAX_REPLANS) {
        const anomaly: Anomaly = this.detectAnomaly(plan);
        if (anomaly.type !== AnomalyType.NONE) {
          replans += 1;
          this.handledAnomalies.add(anomaly.type as string);
          eventBus.emit(BusEvent.ANOMALY_DETECTED, JSON.stringify(anomaly));
          CentralAgent.say(`${anomaly.description}，我重新帮您调整一下。`);
          blackboard.invalidate(TaskPlanner.affectedClosure(plan, anomaly.affectedTasks));
          TaskPlanner.replan(plan, anomaly);
          blackboard.setPlan(plan);
          eventBus.emit(BusEvent.PLAN_UPDATED, JSON.stringify(plan));
        }
      }
    }
    CentralAgent.skipPending(plan);
    eventBus.emit(BusEvent.PLAN_UPDATED, JSON.stringify(plan));

    const journey: JourneyRecord | null = this.buildJourney(plan, rt.nowTs);
    if (journey === null) {
      return CentralAgent.reply(ReplyKind.ERROR, '这次没能生成完整方案，请稍后再试。');
    }
    await JourneyStore.getInstance().saveDraft(journey);
    const finished: Record<string, Object> = { 'journeyId': journey.journeyId, 'partial': journey.partial };
    eventBus.emit(BusEvent.PLAN_FINISHED, JSON.stringify(finished));
    return CentralAgent.reply(journey.partial ? ReplyKind.PLAN_PARTIAL : ReplyKind.PLAN_DONE, journey.summary);
  }

  /** 依赖失败而无法执行的任务标记为跳过，进度面板不会一直显示“等待中” */
  private static skipPending(plan: TaskPlan): void {
    for (let i = 0; i < plan.nodes.length; i++) {
      if (plan.nodes[i].status === TaskStatus.PENDING) {
        plan.nodes[i].status = TaskStatus.SKIPPED;
      }
    }
  }

  private static withMissing(intent: ParsedIntent, slot: string): ParsedIntent {
    const p: ParsedIntent = {
      type: intent.type,
      hospital: slot === SlotName.HOSPITAL ? '' : intent.hospital,
      department: slot === SlotName.DEPARTMENT ? '' : intent.department,
      purpose: intent.purpose,
      expectedDate: slot === SlotName.DATE ? '' : intent.expectedDate,
      timePreference: intent.timePreference,
      isRevisit: intent.isRevisit,
      confidence: intent.confidence,
      missingSlots: [slot],
      clarifyHint: ''
    };
    return p;
  }

  /**
   * 异常检测（每批任务完成后调用）：
   *  - 医生停诊：演示开关开启时，挂号方案出来后模拟医院通知停诊 → 重做 T1 及下游
   *  - 恶劣天气：就诊日预报暴雨/暴雪等，或演示开关开启 → 重做 T2 及下游（T4）
   * 同一类异常只处理一次，避免反复重规划。
   */
  private detectAnomaly(plan: TaskPlan): Anomaly {
    const none: Anomaly = { type: AnomalyType.NONE, description: '', detectedAt: Date.now(), affectedTasks: [], detail: '' };
    const demo: DemoSettings = ContextStore.getInstance().getDemoSettings();

    const t1: TaskNode | null = TaskPlanner.findNode(plan, 'T1');
    if (demo.simulateDoctorOff && t1 !== null && t1.status === TaskStatus.SUCCESS &&
      !this.handledAnomalies.has(AnomalyType.DOCTOR_OFF as string)) {
      const r: AgentResult | undefined = blackboard.getResult('T1');
      let doctor: string = '原定医生';
      if (r !== undefined) {
        const appt: Appointment | null = CentralAgent.appointmentOf(r);
        if (appt !== null) {
          doctor = appt.doctorName;
        }
      }
      const a: Anomaly = {
        type: AnomalyType.DOCTOR_OFF,
        description: `医院刚刚通知，${doctor.split(' ')[0]}医生临时停诊`,
        detectedAt: Date.now(),
        affectedTasks: ['T1'],
        detail: doctor
      };
      return a;
    }

    const t2: TaskNode | null = TaskPlanner.findNode(plan, 'T2');
    if (t2 !== null && t2.status === TaskStatus.SUCCESS && !this.handledAnomalies.has(AnomalyType.HEAVY_RAIN as string)) {
      const r: AgentResult | undefined = blackboard.getResult('T2');
      let weather: string = '';
      if (r !== undefined) {
        const tp: TravelPlan | null = CentralAgent.travelOf(r);
        weather = tp !== null ? tp.weather : '';
      }
      const severe: boolean = /暴雨|大暴雨|暴雪|大雪|冰雹|台风/.test(weather);
      if (demo.simulateStorm || severe) {
        const label: string = demo.simulateStorm && !severe ? '暴雨' : weather;
        const a: Anomaly = {
          type: AnomalyType.HEAVY_RAIN,
          description: `就诊那天有${label}预警`,
          detectedAt: Date.now(),
          affectedTasks: ['T2'],
          detail: label
        };
        return a;
      }
    }
    return none;
  }

  // ==================== 汇总 ====================

  private static dataOf(r: AgentResult): Record<string, Object> | null {
    if (!r.success || r.data.length === 0) {
      return null;
    }
    try {
      return JSON.parse(r.data) as Record<string, Object>;
    } catch (e) {
      return null;
    }
  }

  private static appointmentOf(r: AgentResult): Appointment | null {
    const d: Record<string, Object> | null = CentralAgent.dataOf(r);
    if (d === null) {
      return null;
    }
    const a: Object | undefined = d['appointment'];
    return (a !== undefined && a !== null) ? a as Appointment : null;
  }

  private static travelOf(r: AgentResult): TravelPlan | null {
    const d: Record<string, Object> | null = CentralAgent.dataOf(r);
    if (d === null) {
      return null;
    }
    const t: Object | undefined = d['travelPlan'];
    return (t !== undefined && t !== null) ? t as TravelPlan : null;
  }

  private buildJourney(plan: TaskPlan, nowTs: number): JourneyRecord | null {
    const medical: AgentResult | undefined = blackboard.getResult('T1');
    if (medical === undefined) {
      return null;
    }
    const md: Record<string, Object> | null = CentralAgent.dataOf(medical);
    const appt: Appointment | null = CentralAgent.appointmentOf(medical);
    if (md === null || appt === null) {
      return null;
    }
    const prepObj: Object | undefined = md['preparation'];
    const preparation: MedicalPreparation = (prepObj !== undefined && prepObj !== null)
      ? prepObj as MedicalPreparation : { visitItems: [], materials: [], notices: [] };
    const rxObj: Object | undefined = md['lastPrescription'];

    let travel: TravelPlan | null = null;
    let travelSource: DataSourceType = DataSourceType.UNKNOWN;
    const t2: AgentResult | undefined = blackboard.getResult('T2');
    if (t2 !== undefined && t2.success) {
      travel = CentralAgent.travelOf(t2);
      travelSource = t2.dataSource;
    }

    let nav: IndoorNavPlan | null = null;
    let navSource: DataSourceType = DataSourceType.UNKNOWN;
    const t3: AgentResult | undefined = blackboard.getResult('T3');
    if (t3 !== undefined && t3.success) {
      const nd: Record<string, Object> | null = CentralAgent.dataOf(t3);
      const np: Object | undefined = nd !== null ? nd['navPlan'] : undefined;
      if (np !== undefined && np !== null) {
        nav = np as IndoorNavPlan;
        navSource = t3.dataSource;
      }
    }

    let reminders: ReminderItem[] = [];
    const t4: AgentResult | undefined = blackboard.getResult('T4');
    if (t4 !== undefined && t4.success) {
      const rd: Record<string, Object> | null = CentralAgent.dataOf(t4);
      const rs: Object | undefined = rd !== null ? rd['reminders'] : undefined;
      if (rs !== undefined && Array.isArray(rs)) {
        reminders = rs as ReminderItem[];
      }
    }

    const j: JourneyRecord = {
      journeyId: `j_${Date.now()}`,
      stage: JourneyStage.DRAFT,
      intentType: plan.intent.type,
      purpose: plan.intent.purpose,
      appointment: appt,
      preparation: preparation,
      lastPrescription: typeof rxObj === 'string' ? rxObj : '',
      travel: travel,
      nav: nav,
      reminders: reminders,
      medicalSource: medical.dataSource,
      travelSource: travelSource,
      navSource: navSource,
      partial: travel === null || nav === null || reminders.length === 0,
      summary: '',
      remindersScheduled: 0,
      createdAt: nowTs,
      updatedAt: nowTs
    };
    j.summary = CentralAgent.composeSummary(j, nowTs);
    return j;
  }

  /** 给老人听的汇总：一句话讲清时间地点、何时出发、最后一步要做什么 */
  private static composeSummary(j: JourneyRecord, nowTs: number): string {
    const a: Appointment = j.appointment;
    const day: string = DateUtil.friendlyDate(a.visitDate, nowTs);
    const doctor: string = a.doctorName.split(' ')[0];
    let s: string = `安排好了：${day}${a.visitTime}，${a.hospitalName}${a.department}，${doctor}医生。`;
    if (j.travel !== null) {
      const departTs: number = DateUtil.toTimestamp(a.visitDate, j.travel.departTime);
      const departLabel: string = isNaN(departTs) ? j.travel.departTime : DateUtil.friendlyTime(departTs, nowTs);
      s += `建议${departLabel}出发，路上约${j.travel.durationMin}分钟。`;
      if (j.travel.warning.length > 0) {
        s += `${j.travel.warning}。`;
      }
    }
    if (j.nav !== null) {
      s += `到了从${j.nav.entrance}进，去${a.floor}${a.roomNo}。`;
    }
    if (j.partial) {
      s += '有一部分还没安排好，可以在安排页里查看。';
    }
    const active: JourneyRecord | null = JourneyStore.getInstance().getActive();
    if (active !== null) {
      s += '确认后会替换原来的安排。';
    }
    s += `最后一步：请在${a.officialChannelName}确认挂号，确认后我按时提醒您。`;
    return s;
  }

  // ==================== 已有安排问答 ====================

  answerJourneyQuestion(kind: string, nowTs: number): string {
    const j: JourneyRecord | null = JourneyStore.getInstance().getForDisplay();
    if (j === null) {
      return '';
    }
    const a: Appointment = j.appointment;
    const day: string = DateUtil.friendlyDate(a.visitDate, nowTs);
    const unconfirmed: string = j.stage === JourneyStage.CONFIRMED ? '' : '这个安排还没在官方渠道确认挂号。';
    if (kind === 'DEPART') {
      if (j.travel === null) {
        return `${day}${a.visitTime}看病，出行路线还没规划好，建议提前一小时出门。${unconfirmed}`;
      }
      return `${day}${a.visitTime}看病，建议${j.travel.departTime}出发，路上约${j.travel.durationMin}分钟。${unconfirmed}`;
    }
    if (kind === 'WHEN') {
      return `${day}${a.visitTime}，在${a.hospitalName}${a.department}，看${a.doctorName}。${unconfirmed}`;
    }
    if (kind === 'WHERE') {
      const entrance: string = j.nav !== null ? `到了从${j.nav.entrance}进，` : '';
      return `${entrance}诊室在${a.buildingName}${a.floor}${a.roomNo}。到医院后打开“院内引导”，我一步一步带您走。`;
    }
    if (kind === 'BRING') {
      return `记得带：${j.preparation.materials.join('、')}。`;
    }
    if (kind === 'WEATHER') {
      if (j.travel === null) {
        return '';
      }
      if (j.travel.weather.indexOf('暂无预报') >= 0) {
        return `就诊那天的天气预报还没出来，出门前记得看一眼天气。${j.travel.suggestion}。`;
      }
      return `就诊那天${j.travel.weather}。${j.travel.suggestion}。`;
    }
    return '';
  }

  // ==================== 主动服务 ====================

  /**
   * 检查是否有到期的复诊；已经为同一医院科室安排了未来的行程就不再提醒。
   * 由页面在回到前台时调用，结果以卡片形式展示（每条每天最多播报一次）。
   */
  proactiveCheck(nowTs: number): FollowUpPrompt | null {
    const due: FollowUpPrompt[] = ContextStore.getInstance().findDueFollowUps(nowTs);
    if (due.length === 0) {
      return null;
    }
    const store: JourneyStore = JourneyStore.getInstance();
    const planned: JourneyRecord[] = [];
    const draft: JourneyRecord | null = store.getDraft();
    const active: JourneyRecord | null = store.getActive();
    if (draft !== null) {
      planned.push(draft);
    }
    if (active !== null) {
      planned.push(active);
    }
    const today: string = DateUtil.todayStr(nowTs);
    for (let i = 0; i < due.length; i++) {
      let alreadyPlanned: boolean = false;
      for (let k = 0; k < planned.length; k++) {
        const a: Appointment = planned[k].appointment;
        if (ContextStore.sameHospital(a.hospitalName, due[i].hospital) && a.department === due[i].department &&
          a.visitDate >= today) {
          alreadyPlanned = true;
        }
      }
      if (!alreadyPlanned) {
        return due[i];
      }
    }
    return null;
  }

  /** 用户点“帮我安排复诊”时，拼一句完整的话走正常流程（到期日已过则约明天） */
  static buildFollowUpRequest(p: FollowUpPrompt, nowTs: number): string {
    const tomorrow: string = DateUtil.dateAfter(nowTs, 1);
    const date: string = p.dueDate > tomorrow ? p.dueDate : tomorrow;
    const d: Date | null = DateUtil.parseYmd(date);
    const dateText: string = d !== null ? `${d.getMonth() + 1}月${d.getDate()}号` : '明天';
    return `${dateText}上午去${p.hospital}${p.department}复诊`;
  }
}
