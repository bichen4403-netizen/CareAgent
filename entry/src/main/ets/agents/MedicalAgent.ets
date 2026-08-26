/**
 * 医疗协调智能体
 * 职责：智能挂号｜排班查询｜处方管理｜复诊提醒
 *
 * 它是整条链路的起点 —— 只有先定下就诊时间和诊室，
 * 出行 Agent 才能倒推出发时间，导航 Agent 才知道要去哪一层。
 */

import {
  AgentResult, TaskNode, RuntimeContext, ParsedIntent, Appointment
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import {
  MedicalAssistRequest, MedicalAssistResponse, MedicalAssistService
} from '../services/MedicalAssistService';

export class MedicalAgent extends BaseAgent {
  readonly name: string = 'MedicalAgent';

  protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    const intent: ParsedIntent = JSON.parse(task.payload) as ParsedIntent;
    const payloadObj: Record<string, Object> = JSON.parse(task.payload) as Record<string, Object>;
    const anomalyType: string = (payloadObj['anomalyType'] as string) ?? 'NONE';

    const request: MedicalAssistRequest = {
      hospital: intent.hospital,
      department: intent.department,
      expectedDate: intent.expectedDate,
      purpose: intent.purpose,
      isRevisit: intent.isRevisit
    };
    const response: MedicalAssistResponse = await MedicalAssistService.planVisit(request, anomalyType);
    if (!response.success || response.appointment === null || response.officialChannel === null) {
      const question: string = response.clarifyQuestion.length > 0
        ? response.clarifyQuestion : '暂时没能生成就诊方案，请稍后再试';
      return this.fail(task.id, question, 'medical service needs clarification');
    }
    const appt: Appointment = response.appointment;

    const dataObj: Record<string, Object> = {
      'appointment': appt,
      'lastPrescription': response.lastPrescription,
      'isRevisit': response.isRevisit,
      'replanned': response.replanned,
      'officialChannel': response.officialChannel
    };

    // 这里的"确认"指用户确认这份推荐方案本身，不代表挂号已经完成
    return this.ok(task.id, response.speech, JSON.stringify(dataObj), true);
  }
}
