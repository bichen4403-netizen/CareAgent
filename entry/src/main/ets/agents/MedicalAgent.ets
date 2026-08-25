/**
 * 医疗协调智能体
 * 职责：智能挂号｜排班查询｜处方管理｜复诊提醒
 *
 * 它是整条链路的起点 —— 只有先定下就诊时间和诊室，
 * 出行 Agent 才能倒推出发时间，导航 Agent 才知道要去哪一层。
 */

import {
  AgentResult, TaskNode, RuntimeContext, ParsedIntent, Appointment, IntentType, ServiceRecord, BookingStatus
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import { MockDataSource } from '../services/MockDataSource';
import { ContextStore } from '../core/ContextStore';
import { OfficialChannelRegistry, OfficialChannel } from '../services/AppLinkService';

export class MedicalAgent extends BaseAgent {
  readonly name: string = 'MedicalAgent';

  protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    const intent: ParsedIntent = JSON.parse(task.payload) as ParsedIntent;
    const payloadObj: Record<string, Object> = JSON.parse(task.payload) as Record<string, Object>;
    const anomalyType: string = (payloadObj['anomalyType'] as string) ?? 'NONE';

    const appt: Appointment = await MockDataSource.queryAppointment(
      intent.hospital, intent.department, intent.expectedDate, intent.isRevisit
    );

    // 重规划场景：医生停诊时自动换同科室其他医生并顺延时段
    if (anomalyType === 'DOCTOR_OFF') {
      appt.doctorName = '李慧敏 副主任医师';
      appt.visitTime = '14:30';
      appt.roomNo = '318诊室';
    }

    // 关键：这里生成的只是"推荐方案"，不代表真的挂上了号
    // 智护同行不越权代替医院系统下单，最后一步交给官方渠道确认
    const channel: OfficialChannel = OfficialChannelRegistry.resolve(appt.hospitalAddress);
    appt.bookingStatus = BookingStatus.RECOMMENDED;
    appt.officialChannelName = channel.name;

    const store: ContextStore = ContextStore.getInstance();
    const last: ServiceRecord | null = store.findLastVisit(intent.hospital, intent.department);

    const dataObj: Record<string, Object> = {
      'appointment': appt,
      'lastPrescription': last === null ? '' : last.prescription,
      'isRevisit': intent.isRevisit,
      'replanned': anomalyType === 'DOCTOR_OFF',
      'officialChannel': channel
    };

    const speech: string = MedicalAgent.buildSpeech(appt, intent, anomalyType === 'DOCTOR_OFF', channel);

    // 这里的"确认"指用户确认这份推荐方案本身，不代表挂号已经完成
    return this.ok(task.id, speech, JSON.stringify(dataObj), true);
  }

  private static buildSpeech(a: Appointment, intent: ParsedIntent,
                             replanned: boolean, channel: OfficialChannel): string {
    const dateLabel: string = MedicalAgent.friendlyDate(a.visitDate);

    if (replanned) {
      return `原来的${a.department}医生今天停诊了，我帮您重新看了一下，改约${a.doctorName}，` +
             `${dateLabel}${a.visitTime}，诊室换到${a.roomNo}，稍后还要麻烦您在${channel.name}上确认一下改约`;
    }
    if (intent.type === IntentType.MEDICINE_REFILL) {
      return `帮您找到了${a.hospitalName}${a.department}的号，${dateLabel}${a.visitTime}，` +
             `${a.doctorName}，挂号费${a.registrationFee}元。这只是我帮您选好的方案，` +
             `还需要在${channel.name}上点一下确认，我等会带您过去`;
    }
    return `帮您找到了${a.hospitalName}${a.department}${a.doctorName}的号，` +
           `${dateLabel}${a.visitTime}，挂号费${a.registrationFee}元，` +
           `诊室在${a.buildingName}${a.floor}${a.roomNo}。方案我先帮您定好了，` +
           `最后要去${channel.name}上确认一下才算真的挂上`;
  }

  /** 老年用户更习惯"明天上午"而不是"2026-08-25" */
  private static friendlyDate(dateStr: string): string {
    const target: number = new Date(dateStr).getTime();
    const t: Date = new Date();
    const todayStr: string =
      `${t.getFullYear()}-${`${t.getMonth() + 1}`.padStart(2, '0')}-${`${t.getDate()}`.padStart(2, '0')}`;
    const todayStart: number = new Date(todayStr).getTime();
    const diffDays: number = Math.round((target - todayStart) / (24 * 3600 * 1000));

    if (diffDays === 0) {
      return '今天';
    }
    if (diffDays === 1) {
      return '明天';
    }
    if (diffDays === 2) {
      return '后天';
    }
    const d: Date = new Date(dateStr);
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }
}
