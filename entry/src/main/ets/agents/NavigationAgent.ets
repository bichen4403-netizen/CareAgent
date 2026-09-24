/**
 * 智护同行 - 院内导航 Agent
 *
 * 职责：根据挂号方案（楼栋/楼层/诊室）生成从医院正门到诊室的分步指引；
 * 续方取药场景额外追加“缴费 → 药房取药”路线。
 * 到院后由“院内引导”页逐步语音播报（buildStepSpeech），戴耳机即可边走边听。
 * 院内地图没有公开接口，初赛使用演示数据，结果标注 DEMO。
 */

import {
  AgentResult, TaskNode, RuntimeContext, Appointment, IndoorNavPlan, NavStep, DataSourceType,
  VerificationStatus
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import { blackboard } from '../core/EventBus';
import { MockDataSource } from '../services/MockDataSource';

export class NavigationAgent extends BaseAgent {
  readonly name: string = 'NavigationAgent';

  protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    const medical: AgentResult | undefined = blackboard.getResult('T1');
    if (medical === undefined || !medical.success) {
      return this.fail(task.id, '还没有确定去哪个诊室，暂时没法规划院内路线', 'NO_APPOINTMENT');
    }
    const md: Record<string, Object> = BaseAgent.parseRecord(medical.data);
    const apptObj: Object | undefined = md['appointment'];
    if (apptObj === undefined || apptObj === null) {
      return this.fail(task.id, '挂号信息不完整，暂时没法规划院内路线', 'BAD_APPOINTMENT');
    }
    const appt: Appointment = apptObj as Appointment;

    const nav: IndoorNavPlan = MockDataSource.queryIndoorNav(appt.buildingName, appt.floor, appt.roomNo);
    if (BaseAgent.strOf(md, 'intentType') === 'MEDICINE_REFILL') {
      const pharmacy: IndoorNavPlan = MockDataSource.queryPharmacyNav();
      for (let i = 0; i < pharmacy.steps.length; i++) {
        const step: NavStep = {
          order: nav.steps.length + 1,
          instruction: pharmacy.steps[i].instruction,
          landmark: pharmacy.steps[i].landmark
        };
        nav.steps.push(step);
      }
      nav.estimatedWalkMin += pharmacy.estimatedWalkMin;
    }

    const speech: string = `到了医院从${nav.entrance}进，诊室在${appt.buildingName}${appt.floor}${appt.roomNo}，` +
      `走过去大约${nav.estimatedWalkMin}分钟。到医院后打开“院内引导”，我一步一步带您走。`;
    const data: Record<string, Object> = { 'navPlan': nav };
    return this.ok(task.id, speech, JSON.stringify(data), false, DataSourceType.DEMO, VerificationStatus.SUGGESTED);
  }

  /** 到院后逐步播报的话术（院内引导页使用） */
  static buildStepSpeech(nav: IndoorNavPlan, stepIndex: number): string {
    if (stepIndex < 0 || stepIndex >= nav.steps.length) {
      return `已经到了，您要去的是${nav.targetRoom}。`;
    }
    const s: NavStep = nav.steps[stepIndex];
    const tail: string = stepIndex === nav.steps.length - 1 ? '这是最后一步。' : '做完了点“下一步”。';
    return `第${stepIndex + 1}步，共${nav.steps.length}步。${s.instruction}。${s.landmark}。${tail}`;
  }
}
