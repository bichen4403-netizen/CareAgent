/**
 * 关怀提醒智能体
 * 职责：证件提醒｜排队提醒｜用药提醒｜服务记录
 *
 * 本 Agent 是"主动服务"最直接的承载者：
 * 它把前三个 Agent 产出的时间点，翻译成一串定时触达任务，
 * 并按场景选择最合适的设备与方式（手表震动 / 耳机语音 / 手机卡片）。
 */

import {
  AgentResult, TaskNode, RuntimeContext, ParsedIntent, Appointment,
  TravelPlan, IndoorNavPlan, ReminderItem, IntentType
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import { blackboard } from '../core/EventBus';
import { MockDataSource } from '../services/MockDataSource';
import { ContextStore } from '../core/ContextStore';

export class ReminderAgent extends BaseAgent {
  readonly name: string = 'ReminderAgent';

  protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    const intent: ParsedIntent = JSON.parse(task.payload) as ParsedIntent;

    const medicalResult = blackboard.getResultByAgent('MedicalAgent');
    const travelResult = blackboard.getResultByAgent('TravelAgent');
    if (medicalResult === undefined || travelResult === undefined) {
      return this.fail(task.id, '提醒还没设好，我稍后补上', 'upstream result missing');
    }

    const medicalData: Record<string, Object> = JSON.parse(medicalResult.data) as Record<string, Object>;
    const appt: Appointment = medicalData['appointment'] as Appointment;
    const travelData: Record<string, Object> = JSON.parse(travelResult.data) as Record<string, Object>;
    const travel: TravelPlan = travelData['travelPlan'] as TravelPlan;

    const items: ReminderItem[] = ReminderAgent.buildReminders(appt, travel, intent);

    const speech: string = `我已经把${items.length}个提醒都设好了：` +
                           `出门前提醒您带医保卡和身份证，${travel.departTime}手表会震动提醒出发，` +
                           `到院排队和吃药我也会按时叫您`;

    const dataObj: Record<string, Object> = { 'reminders': items };
    return this.ok(task.id, speech, JSON.stringify(dataObj), false);
  }

  /**
   * 生成全流程提醒链
   * 设备选择原则：
   *   - 出发提醒 → 手表震动（手机常在包里，老人看不到）
   *   - 院内导航 → 耳机语音（双手解放，不用边走边看屏幕）
   *   - 证件/用药 → 手机卡片（信息量大，需要看清楚）
   */
  private static buildReminders(appt: Appointment, travel: TravelPlan,
                                intent: ParsedIntent): ReminderItem[] {
    const items: ReminderItem[] = [];
    const departTs: number = MockDataSource.toTimestamp(appt.visitDate, travel.departTime);

    // 1. 前一晚证件准备提醒
    items.push({
      id: 'R1',
      title: '明天就诊，别忘了带证件',
      content: '医保卡、身份证、上次的检查报告，建议今晚就放到包里',
      triggerAt: departTs - 12 * 3600 * 1000,
      targetDevice: 'phone',
      channel: 'card',
      fired: false
    });

    // 2. 出发前 20 分钟准备提醒
    items.push({
      id: 'R2',
      title: '准备出门了',
      content: `${travel.departTime}出发，${travel.suggestion}`,
      triggerAt: departTs - 20 * 60 * 1000,
      targetDevice: 'phone',
      channel: 'card',
      fired: false
    });

    // 3. 出发时刻手表震动
    items.push({
      id: 'R3',
      title: '该出发了',
      content: `现在出发，${travel.durationMin}分钟到${appt.hospitalName}`,
      triggerAt: departTs,
      targetDevice: 'watch',
      channel: 'vibrate',
      fired: false
    });

    // 4. 预计到院时的院内引导（耳机语音）
    const arriveTs: number = departTs + (travel.durationMin + travel.bufferMin) * 60 * 1000;
    items.push({
      id: 'R4',
      title: '到院引导',
      content: `先取号，然后到${appt.buildingName}${appt.floor}${appt.roomNo}`,
      triggerAt: arriveTs,
      targetDevice: 'earphone',
      channel: 'voice',
      fired: false
    });

    // 5. 就诊前 10 分钟排队提醒
    const visitTs: number = MockDataSource.toTimestamp(appt.visitDate, appt.visitTime);
    items.push({
      id: 'R5',
      title: '快轮到您了',
      content: `${appt.queueNo}号，请到${appt.roomNo}门口等候`,
      triggerAt: visitTs - 10 * 60 * 1000,
      targetDevice: 'watch',
      channel: 'vibrate',
      fired: false
    });

    // 6. 用药提醒（取药场景当天开始，就诊场景次日开始）
    const medStartTs: number = intent.type === IntentType.MEDICINE_REFILL
      ? visitTs + 4 * 3600 * 1000
      : visitTs + 24 * 3600 * 1000;
    items.push({
      id: 'R6',
      title: '该吃药了',
      content: '按医生嘱咐按时服药，吃完在手表上点一下告诉我',
      triggerAt: medStartTs,
      targetDevice: 'watch',
      channel: 'vibrate',
      fired: false
    });

    return items;
  }

  /**
   * 主动服务入口：扫描到期复诊，主动发起下一次陪诊规划
   * 由后台任务定时调用，是"下次复诊自动提前规划"的实现
   */
  static async scanDueFollowUps(nowTs: number): Promise<string> {
    const store: ContextStore = ContextStore.getInstance();
    const due = store.findDueFollowUps(nowTs);
    if (due.length === 0) {
      return '';
    }
    const r = due[0];
    return `距离上次在${r.hospital}${r.department}看诊快到复诊时间了，` +
           `需要我现在帮您约${r.doctorName}的号吗？`;
  }
}
