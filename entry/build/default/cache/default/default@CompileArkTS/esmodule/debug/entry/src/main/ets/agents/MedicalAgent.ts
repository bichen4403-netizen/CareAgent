import type { AgentResult, TaskNode, RuntimeContext, ParsedIntent, Appointment } from '../core/AgentTypes';
import { BaseAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/BaseAgent";
import { MedicalAssistService } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/MedicalAssistService";
import type { MedicalAssistRequest, MedicalAssistResponse } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/MedicalAssistService";
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
