/**
 * 智护同行 - 医疗 Agent
 *
 * 职责：根据意图生成挂号推荐方案与就诊准备清单。
 * 业务规则全部在 MedicalAssistService，这里只负责“任务输入 → 服务请求 → 统一结果”。
 * 缺信息或当天约不上时返回失败，errorMsg 形如 NEED_CLARIFICATION:<槽位>，由中枢继续追问。
 */

import {
  AgentResult, TaskNode, RuntimeContext, IntentType, ServiceRecord
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import { ContextStore } from '../core/ContextStore';
import {
  MedicalAssistRequest, MedicalAssistResponse, MedicalAssistService
} from '../services/MedicalAssistService';

export class MedicalAgent extends BaseAgent {
  readonly name: string = 'MedicalAgent';

  private static toIntentType(s: string): IntentType {
    if (s === 'MEDICAL_VISIT') {
      return IntentType.MEDICAL_VISIT;
    }
    if (s === 'MEDICINE_REFILL') {
      return IntentType.MEDICINE_REFILL;
    }
    if (s === 'REPORT_QUERY') {
      return IntentType.REPORT_QUERY;
    }
    return IntentType.UNKNOWN;
  }

  protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    const payload: Record<string, Object> = BaseAgent.payloadOf(task);
    const anomaly: Record<string, Object> | null = BaseAgent.anomalyOf(payload);
    const hospital: string = BaseAgent.strOf(payload, 'hospital');
    const department: string = BaseAgent.strOf(payload, 'department');
    const last: ServiceRecord | null = ContextStore.getInstance().findLastVisit(hospital, department);

    const req: MedicalAssistRequest = {
      intentType: MedicalAgent.toIntentType(BaseAgent.strOf(payload, 'type')),
      hospital: hospital,
      department: department,
      purpose: BaseAgent.strOf(payload, 'purpose'),
      expectedDate: BaseAgent.strOf(payload, 'expectedDate'),
      timePreference: BaseAgent.strOf(payload, 'timePreference'),
      isRevisit: BaseAgent.boolOf(payload, 'isRevisit'),
      anomalyType: anomaly !== null ? BaseAgent.strOf(anomaly, 'anomalyType') : '',
      avoidDoctor: anomaly !== null ? BaseAgent.strOf(anomaly, 'detail') : '',
      originLng: rt.currentLng,
      originLat: rt.currentLat,
      cityName: rt.cityName,
      lastPrescription: last !== null ? last.prescription : ''
    };

    const resp: MedicalAssistResponse = await MedicalAssistService.planVisit(req, rt.nowTs);
    if (!resp.success || resp.appointment === null) {
      const speech: string = resp.clarificationQuestion.length > 0 ? resp.clarificationQuestion : '挂号方案暂时生成不了';
      return this.fail(task.id, speech, resp.errorMsg.length > 0 ? resp.errorMsg : 'NO_APPOINTMENT');
    }

    const data: Record<string, Object> = {
      'appointment': resp.appointment,
      'preparation': resp.preparation,
      'lastPrescription': resp.lastPrescription,
      'officialChannel': resp.officialChannel,
      'intentType': req.intentType as string
    };
    return this.ok(task.id, resp.speech, JSON.stringify(data), true, resp.dataSource, resp.verificationStatus);
  }
}
