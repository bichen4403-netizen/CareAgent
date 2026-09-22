/**
 * 导航引导智能体
 * 职责：院内导航｜科室指引｜路径规划｜楼层定位
 *
 * 老年用户在医院最容易迷路的是"进门之后"这一段，
 * 所以本 Agent 专注院内引导，且输出为可直接语音播报的口语化步骤。
 */

import {
  AgentResult, TaskNode, RuntimeContext, ParsedIntent, Appointment, IndoorNavPlan, IntentType, NavStep,
  DataSourceType, VerificationStatus
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import { blackboard } from '../core/EventBus';
import { MockDataSource } from '../services/MockDataSource';

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
    } else {
      navPlan = await MockDataSource.queryIndoorNav(
        appt.hospitalName, appt.buildingName, appt.floor, appt.roomNo
      );
    }

    const speech: string = `到院后从${navPlan.entrance}进，我会一步步语音告诉您怎么走到${navPlan.targetRoom}，` +
                           `走路大约${navPlan.estimatedWalkMin}分钟`;

    const dataObj: Record<string, Object> = {
      'navPlan': navPlan,
      'targetRoom': navPlan.targetRoom
    };

    return this.ok(task.id, speech, JSON.stringify(dataObj), false,
      DataSourceType.DEMO, VerificationStatus.UNVERIFIED);
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
