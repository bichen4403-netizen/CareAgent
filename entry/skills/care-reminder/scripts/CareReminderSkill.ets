import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 上传到小艺开放平台的 Skill 必须自包含：不 import App 内 src/main/ets 的任何文件。
 * 只生成提醒计划（registered=false），用户在官方渠道确认挂号后才由 App 注册到系统。
 * 时间链与 App 内提醒 Agent 一致：
 *   前一晚 20:00 备证件（已过则出发前 1 小时）→ 出发前 20 分钟 → 出发 → 预计到院 → 就诊前 10 分钟
 * 已经过去的时间点不生成；相隔不到 5 分钟的提醒合并为一条。
 */

interface AppointmentInput {
  hospitalName: string;
  department: string;
  visitDate: string;
  visitTime: string;
  queueNo: string;
  buildingName: string;
  floor: string;
  roomNo: string;
}

interface TravelInput {
  departTime: string;
  durationMin: number;
  bufferMin: number;
  weather: string;
  suggestion: string;
}

interface ReminderData {
  id: string;
  title: string;
  content: string;
  triggerAt: number;
  targetDevice: string;
  channel: string;
  fired: boolean;
}

const MINUTE: number = 60 * 1000;

export default class CareReminderSkill {
  public async createReminderPlan(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    const appointmentJson: string = argv.length > 0 ? argv[0].trim() : '';
    const travelJson: string = argv.length > 1 ? argv[1].trim() : '';
    if (appointmentJson.length === 0 || travelJson.length === 0) {
      await this.fail(info, 'ERR_INVALID_PARAMS', 'appointment or travelPlan is empty',
        '需要先完成就诊和出行安排');
      return;
    }
    let appointment: AppointmentInput;
    let travel: TravelInput;
    try {
      appointment = CareReminderSkill.parseAppointment(appointmentJson);
      travel = CareReminderSkill.parseTravel(travelJson);
    } catch (e) {
      await this.fail(info, 'ERR_INVALID_PARAMS', 'appointment or travelPlan is invalid json',
        '就诊或出行方案格式不对，请重新生成');
      return;
    }
    try {
      const reminders: ReminderData[] = CareReminderSkill.buildReminders(appointment, travel, Date.now());
      if (reminders.length === 0) {
        await this.fail(info, 'ERR_INTERNAL', 'all reminder times have passed', '就诊时间已经很近，来不及设置提前提醒');
        return;
      }
      const data: Record<string, Object> = {
        'reminders': reminders,
        'registered': false,
        'speech': `已经为您整理好${reminders.length}个提醒，确认挂号后才会正式开启`
      };
      const payload: Record<string, Object> = {
        'type': 'result',
        'status': 'success',
        'data': data
      };
      await this.report(info, { code: 0, result: payload });
    } catch (e) {
      const err = e as Error;
      await this.fail(info, 'ERR_INTERNAL', err.message, '提醒计划生成失败，请稍后再试');
    }
  }

  private static str(obj: Record<string, Object>, key: string): string {
    const v: Object | undefined = obj[key];
    return typeof v === 'string' ? v : '';
  }

  private static num(obj: Record<string, Object>, key: string): number {
    const v: Object | undefined = obj[key];
    return typeof v === 'number' && isFinite(v) ? v : 0;
  }

  private static parseAppointment(raw: string): AppointmentInput {
    const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const a: AppointmentInput = {
      hospitalName: CareReminderSkill.str(obj, 'hospitalName'),
      department: CareReminderSkill.str(obj, 'department'),
      visitDate: CareReminderSkill.str(obj, 'visitDate'),
      visitTime: CareReminderSkill.str(obj, 'visitTime'),
      queueNo: CareReminderSkill.str(obj, 'queueNo'),
      buildingName: CareReminderSkill.str(obj, 'buildingName'),
      floor: CareReminderSkill.str(obj, 'floor'),
      roomNo: CareReminderSkill.str(obj, 'roomNo')
    };
    return a;
  }

  private static parseTravel(raw: string): TravelInput {
    const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const t: TravelInput = {
      departTime: CareReminderSkill.str(obj, 'departTime'),
      durationMin: CareReminderSkill.num(obj, 'durationMin'),
      bufferMin: CareReminderSkill.num(obj, 'bufferMin'),
      weather: CareReminderSkill.str(obj, 'weather'),
      suggestion: CareReminderSkill.str(obj, 'suggestion')
    };
    return t;
  }

  /** YYYY-MM-DD + HH:mm → 本地时间戳，格式不对返回 NaN */
  private static toTimestamp(ymd: string, hhmm: string): number {
    const d: RegExpMatchArray | null = ymd.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
    const t: RegExpMatchArray | null = hhmm.match(/^(\d{1,2}):(\d{2})$/);
    if (d === null || t === null) {
      return NaN;
    }
    return new Date(Number(d[1]), Number(d[2]) - 1, Number(d[3]), Number(t[1]), Number(t[2]), 0).getTime();
  }

  private static item(id: string, title: string, content: string, triggerAt: number,
    device: string, channel: string): ReminderData {
    const r: ReminderData = {
      id: id,
      title: title,
      content: content.length > 0 ? content : title,
      triggerAt: triggerAt,
      targetDevice: device,
      channel: channel,
      fired: false
    };
    return r;
  }

  private static buildReminders(a: AppointmentInput, t: TravelInput, nowTs: number): ReminderData[] {
    const visitAt: number = CareReminderSkill.toTimestamp(a.visitDate, a.visitTime);
    let departAt: number = CareReminderSkill.toTimestamp(a.visitDate, t.departTime);
    if (isNaN(visitAt)) {
      throw new Error('visitDate or visitTime is invalid');
    }
    if (isNaN(departAt)) {
      departAt = visitAt - 60 * MINUTE;
    }
    const all: ReminderData[] = [];
    const eve: Date = new Date(visitAt);
    let prepareAt: number = new Date(eve.getFullYear(), eve.getMonth(), eve.getDate() - 1, 20, 0, 0).getTime();
    let prepareTitle: string = '明天去医院，今晚把东西备好';
    if (prepareAt <= nowTs) {
      prepareAt = departAt - 60 * MINUTE;
      prepareTitle = '快出门了，东西带齐了吗';
    }
    all.push(CareReminderSkill.item('R1', prepareTitle, '请准备身份证、医保卡和上次的病历或检查报告',
      prepareAt, 'phone', 'card'));
    const tip: string = t.weather.length > 0 ? `${t.weather}，${t.suggestion}` : t.suggestion;
    all.push(CareReminderSkill.item('R2', '20分钟后该出发了', tip, departAt - 20 * MINUTE, 'watch', 'vibrate'));
    all.push(CareReminderSkill.item('R3', '该出发去医院啦',
      `去${a.hospitalName}，路上约${t.durationMin}分钟`, departAt, 'watch', 'vibrate'));
    all.push(CareReminderSkill.item('R4', '快到医院了',
      `到了从正门进，去${a.buildingName}${a.floor}${a.roomNo}，打开院内引导一步一步走`,
      departAt + t.durationMin * MINUTE, 'earphone', 'voice'));
    const queue: string = a.queueNo.length > 0 ? `（排队号${a.queueNo}，以医院实际为准）` : '';
    all.push(CareReminderSkill.item('R5', '快轮到您看病了',
      `请到${a.roomNo}门口候诊区坐好，留意叫号${queue}`, visitAt - 10 * MINUTE, 'watch', 'vibrate'));

    all.sort((x: ReminderData, y: ReminderData) => x.triggerAt - y.triggerAt);
    const out: ReminderData[] = [];
    for (let i = 0; i < all.length; i++) {
      const cur: ReminderData = all[i];
      if (cur.triggerAt <= nowTs) {
        continue;
      }
      if (out.length > 0 && cur.triggerAt - out[out.length - 1].triggerAt < 5 * MINUTE) {
        const prev: ReminderData = out[out.length - 1];
        prev.content = `${prev.content}；${cur.title}：${cur.content}`;
        continue;
      }
      out.push(cur);
    }
    return out;
  }

  private async fail(info: scriptManager.ArkTSScriptInfo, errCode: string,
    errMsg: string, suggestion: string): Promise<void> {
    await this.report(info, {
      code: -1,
      result: {
        'type': 'result', 'status': 'failed', 'errCode': errCode,
        'errMsg': errMsg, 'suggestion': suggestion
      }
    });
  }

  private async report(info: scriptManager.ArkTSScriptInfo,
    result: scriptManager.ExecuteResult): Promise<void> {
    try {
      await scriptManager.completeArkTSScriptInApp(info.context, info.requestCode, result);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[CareReminderSkill] report failed: ${err.code}, ${err.message}`);
    }
  }
}
