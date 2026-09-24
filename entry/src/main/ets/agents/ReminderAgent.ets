/**
 * 智护同行 - 提醒 Agent
 *
 * 汇总医疗 / 出行 / 导航三个 Agent 的结果，生成全流程提醒链：
 *   前一晚 20:00  备好证件（当天就诊则改为出发前 1 小时）      → 手机
 *   出发前 20 分钟 收拾出门，提示天气与交通方式                → 手机 + 手表
 *   出发时刻       该出发了                                    → 手机 + 手表
 *   预计到院       打开院内引导，耳机里一步一步听               → 耳机语音
 *   就诊前 10 分钟 到诊室门口候诊                              → 手机 + 手表
 *   就诊后 3 小时  拍处方单，记下复诊时间（取药场景提醒按新处方吃药）→ 手机
 * 相隔不到 5 分钟的提醒合并成一条，避免连续打扰。
 * 提醒要等用户在官方渠道确认挂号后才会注册到系统。
 */

import {
  AgentResult, TaskNode, RuntimeContext, Appointment, TravelPlan, IndoorNavPlan, ReminderItem, ReminderKind,
  MedicalPreparation, DataSourceType, VerificationStatus
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import { blackboard } from '../core/EventBus';
import { DateUtil } from '../core/DateUtil';

const MINUTE: number = 60 * 1000;

export class ReminderAgent extends BaseAgent {
  readonly name: string = 'ReminderAgent';

  protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    const medical: AgentResult | undefined = blackboard.getResult('T1');
    if (medical === undefined || !medical.success) {
      return this.fail(task.id, '挂号方案还没定，暂时不能设置提醒', 'NO_APPOINTMENT');
    }
    const md: Record<string, Object> = BaseAgent.parseRecord(medical.data);
    const apptObj: Object | undefined = md['appointment'];
    if (apptObj === undefined || apptObj === null) {
      return this.fail(task.id, '挂号信息不完整，暂时不能设置提醒', 'BAD_APPOINTMENT');
    }
    const appt: Appointment = apptObj as Appointment;
    const prepObj: Object | undefined = md['preparation'];
    const materials: string[] = (prepObj !== undefined && prepObj !== null)
      ? (prepObj as MedicalPreparation).materials : ['身份证', '医保卡'];
    const isRefill: boolean = BaseAgent.strOf(md, 'intentType') === 'MEDICINE_REFILL';

    const visitTs: number = DateUtil.toTimestamp(appt.visitDate, appt.visitTime);
    if (isNaN(visitTs)) {
      return this.fail(task.id, '看病时间格式不对，暂时不能设置提醒', 'BAD_VISIT_TIME');
    }

    let travel: TravelPlan | null = null;
    let departTs: number = visitTs - 60 * MINUTE;
    const travelResult: AgentResult | undefined = blackboard.getResult('T2');
    if (travelResult !== undefined && travelResult.success) {
      const td: Record<string, Object> = BaseAgent.parseRecord(travelResult.data);
      const tp: Object | undefined = td['travelPlan'];
      if (tp !== undefined && tp !== null) {
        travel = tp as TravelPlan;
      }
      departTs = BaseAgent.numOf(td, 'departTs', departTs);
    }
    let nav: IndoorNavPlan | null = null;
    const navResult: AgentResult | undefined = blackboard.getResult('T3');
    if (navResult !== undefined && navResult.success) {
      const nd: Record<string, Object> = BaseAgent.parseRecord(navResult.data);
      const np: Object | undefined = nd['navPlan'];
      if (np !== undefined && np !== null) {
        nav = np as IndoorNavPlan;
      }
    }

    const day: string = DateUtil.friendlyDate(appt.visitDate, rt.nowTs);
    const items: ReminderItem[] = [];

    // 1. 备证件：前一晚 20:00；已过或当天就诊则改为出发前 1 小时
    let prepareTs: number = DateUtil.toTimestamp(DateUtil.addDays(appt.visitDate, -1), '20:00');
    let prepareTitle: string = '明天去医院，今晚把东西备好';
    if (isNaN(prepareTs) || prepareTs <= rt.nowTs) {
      prepareTs = departTs - 60 * MINUTE;
      prepareTitle = '快出门了，东西带齐了吗';
    }
    // 就诊日超出预报范围时，出行方案里的天气是“暂无预报”，提醒里改成“出门前看天气”
    const noForecast: boolean = travel !== null && travel.weather.indexOf('暂无预报') >= 0;
    const weatherCheck: string = noForecast ? '；出门前看看天气预报' : '';
    items.push(ReminderAgent.item('R1', ReminderKind.PREPARE, prepareTitle,
      `${day}${appt.visitTime}看${appt.department}。请带好：${materials.join('、')}${weatherCheck}`, prepareTs,
      'phone', 'card'));

    // 2. 出发前 20 分钟
    let weatherTip: string = '记得带好证件和手机';
    if (travel !== null) {
      weatherTip = noForecast ? `出门前看一眼天气，${travel.suggestion}` : `${travel.weather}，${travel.suggestion}`;
    }
    items.push(ReminderAgent.item('R2', ReminderKind.DEPART_SOON, '20分钟后该出发了',
      weatherTip, departTs - 20 * MINUTE, 'watch', 'vibrate'));

    // 3. 出发时刻
    const durationText: string = travel !== null ? `，路上约${travel.durationMin}分钟` : '';
    items.push(ReminderAgent.item('R3', ReminderKind.DEPART, '该出发去医院啦',
      `去${appt.hospitalName}${durationText}`, departTs, 'watch', 'vibrate'));

    // 4. 预计到院：打开院内引导
    const arriveTs: number = travel !== null ? departTs + travel.durationMin * MINUTE : visitTs - 25 * MINUTE;
    const target: string = nav !== null ? nav.targetRoom : `${appt.floor}${appt.roomNo}`;
    items.push(ReminderAgent.item('R4', ReminderKind.ARRIVE, '快到医院了',
      `点这条提醒打开院内引导，一步一步带您到${target}`, arriveTs, 'earphone', 'voice'));

    // 5. 候诊
    const queueText: string = appt.queueNo.length > 0 ? `（排队号${appt.queueNo}，以医院实际为准）` : '';
    items.push(ReminderAgent.item('R5', ReminderKind.QUEUE, '快轮到您看病了',
      `请到${appt.roomNo}门口候诊区坐好，留意叫号${queueText}`, visitTs - 10 * MINUTE, 'watch', 'vibrate'));

    // 6. 看完病：取药场景提醒按新处方吃药；看病场景提醒记录复诊时间
    if (isRefill) {
      items.push(ReminderAgent.item('R6', ReminderKind.MEDICATION, '记得按新处方吃药',
        '拿到药后按医生这次开的处方吃，药名和用量以处方单为准。拍一下处方单，我帮您记下来', visitTs + 3 * 60 * MINUTE,
        'phone', 'card'));
    } else {
      items.push(ReminderAgent.item('R6', ReminderKind.POST_VISIT, '看完病了吗',
        '点开告诉我医生让您多久后复查，我到时候提前帮您安排', visitTs + 3 * 60 * MINUTE, 'phone', 'card'));
    }

    const merged: ReminderItem[] = ReminderAgent.mergeClose(items);
    const upcoming: number = ReminderAgent.countUpcoming(merged, rt.nowTs);
    const speech: string = upcoming > 0
      ? `我排好了${upcoming}个提醒：出发前、出发时、到医院和快叫号时都会叫您。确认挂号后就开始生效。`
      : '就诊时间很近了，来不及设置提前提醒，请现在就准备出发。';
    const data: Record<string, Object> = { 'reminders': merged };
    return this.ok(task.id, speech, JSON.stringify(data), false, DataSourceType.LOCAL_COMPUTED,
      VerificationStatus.SUGGESTED);
  }

  private static item(id: string, kind: string, title: string, content: string, triggerAt: number,
    device: string, channel: string): ReminderItem {
    const r: ReminderItem = {
      id: id,
      kind: kind,
      title: title,
      content: content,
      triggerAt: triggerAt,
      targetDevice: device,
      channel: channel,
      fired: false
    };
    return r;
  }

  /** 按时间排序，相隔不到 5 分钟的合并到前一条 */
  private static mergeClose(items: ReminderItem[]): ReminderItem[] {
    const sorted: ReminderItem[] = items.slice();
    sorted.sort((a: ReminderItem, b: ReminderItem) => a.triggerAt - b.triggerAt);
    const out: ReminderItem[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const cur: ReminderItem = sorted[i];
      if (out.length > 0) {
        const prev: ReminderItem = out[out.length - 1];
        if (cur.triggerAt - prev.triggerAt < 5 * MINUTE) {
          prev.content = `${prev.content}；${cur.title}：${cur.content}`;
          continue;
        }
      }
      out.push(cur);
    }
    return out;
  }

  private static countUpcoming(items: ReminderItem[], nowTs: number): number {
    let n: number = 0;
    for (let i = 0; i < items.length; i++) {
      if (items[i].triggerAt > nowTs + 30 * 1000) {
        n += 1;
      }
    }
    return n;
  }
}
