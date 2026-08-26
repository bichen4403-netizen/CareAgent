import { IntentType } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
import type { AgentResult, TaskNode, RuntimeContext, ParsedIntent, Appointment, IndoorNavPlan, NavStep } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
import { BaseAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/BaseAgent";
import { blackboard } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/EventBus";
import { MockDataSource } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/MockDataSource";
export class NavigationAgent extends BaseAgent {
    readonly name: string = 'NavigationAgent';
    protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
        const intent: ParsedIntent = JSON.parse(task.payload) as ParsedIntent;
        const medicalResult = blackboard.getResultByAgent('MedicalAgent');
        if (medicalResult === undefined) {
            return this.fail(task.id, '还没拿到诊室信息，到院后我再为您带路', 'medical result missing');
        }
        const medicalData: Record<string, Object> = JSON.parse(medicalResult.data) as Record<string, Object>;
        const appt: Appointment = medicalData['appointment'] as Appointment;
        let navPlan: IndoorNavPlan;
        if (intent.type === IntentType.MEDICINE_REFILL) {
            navPlan = await MockDataSource.queryPharmacyNav(appt.hospitalName);
        }
        else {
            navPlan = await MockDataSource.queryIndoorNav(appt.hospitalName, appt.buildingName, appt.floor, appt.roomNo);
        }
        const speech: string = `到院后从${navPlan.entrance}进，我会一步步语音告诉您怎么走到${navPlan.targetRoom}，` +
            `走路大约${navPlan.estimatedWalkMin}分钟`;
        const dataObj: Record<string, Object> = {
            'navPlan': navPlan,
            'targetRoom': navPlan.targetRoom
        };
        return this.ok(task.id, speech, JSON.stringify(dataObj), false);
    }
    /**
     * 到院后逐步播报：由页面在用户实际到达时逐条调用
     * 耳机播报优先，避免老人边走边看手机
     */
    static buildStepSpeech(navPlan: IndoorNavPlan, stepIndex: number): string {
        if (stepIndex < 0 || stepIndex >= navPlan.steps.length) {
            return '您已经到了，我在这儿等您看完诊';
        }
        const step: NavStep = navPlan.steps[stepIndex];
        return `第${step.order}步，${step.instruction}`;
    }
}
