import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Appointment, ReminderItem, TravelPlan } from '../../../src/main/ets/core/AgentTypes';
import { MockDataSource } from '../../../src/main/ets/services/MockDataSource';

/** 将陪诊时间节点转换为提醒计划；本入口只生成计划，不直接执行付费操作。 */
export default class CareReminderSkill {
  public async createReminderPlan(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    const appointmentJson: string = argv.length > 0 ? argv[0].trim() : '';
    const travelJson: string = argv.length > 1 ? argv[1].trim() : '';
    if (appointmentJson.length === 0 || travelJson.length === 0) {
      await this.fail(info, 'ERR_INVALID_PARAMS', 'appointment or travelPlan is empty',
        '需要先完成就诊和出行安排');
      return;
    }

    try {
      const appointment: Appointment = JSON.parse(appointmentJson) as Appointment;
      const travel: TravelPlan = JSON.parse(travelJson) as TravelPlan;
      const reminders: ReminderItem[] = CareReminderSkill.buildReminders(appointment, travel);
      const data: Record<string, Object> = {
        'reminders': reminders,
        'registered': false,
        'speech': `已经为您整理好${reminders.length}个提醒，确认方案后才会正式开启`
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

  private static buildReminders(appointment: Appointment, travel: TravelPlan): ReminderItem[] {
    const departAt: number = MockDataSource.toTimestamp(appointment.visitDate, travel.departTime);
    const visitAt: number = MockDataSource.toTimestamp(appointment.visitDate, appointment.visitTime);
    return [
      {
        id: 'R1', title: '明天就诊，别忘了带证件',
        content: '请准备医保卡、身份证和上次检查报告',
        triggerAt: departAt - 12 * 3600 * 1000, targetDevice: 'phone', channel: 'card', fired: false
      },
      {
        id: 'R2', title: '准备出门了', content: `${travel.departTime}出发，${travel.suggestion}`,
        triggerAt: departAt - 20 * 60 * 1000, targetDevice: 'phone', channel: 'card', fired: false
      },
      {
        id: 'R3', title: '该出发了',
        content: `现在出发，约${travel.durationMin}分钟到${appointment.hospitalName}`,
        triggerAt: departAt, targetDevice: 'watch', channel: 'vibrate', fired: false
      },
      {
        id: 'R4', title: '到院引导',
        content: `请前往${appointment.buildingName}${appointment.floor}${appointment.roomNo}`,
        triggerAt: departAt + (travel.durationMin + travel.bufferMin) * 60 * 1000,
        targetDevice: 'earphone', channel: 'voice', fired: false
      },
      {
        id: 'R5', title: '快轮到您了', content: `请到${appointment.roomNo}门口等候`,
        triggerAt: visitAt - 10 * 60 * 1000, targetDevice: 'watch', channel: 'vibrate', fired: false
      }
    ];
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
