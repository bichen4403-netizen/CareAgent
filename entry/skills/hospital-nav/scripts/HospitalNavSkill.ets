import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 上传到小艺开放平台的 Skill 必须自包含：不 import App 内 src/main/ets 的任何文件。
 * 院内地图暂无公开接口，返回的是“到院后核对”的引导模板，不能当作医院实时地图。
 * 不输出某个医院的固定电梯、自助机、药房位置或步行时间。
 */

interface NavStepData {
  order: number;
  instruction: string;
  landmark: string;
}

interface NavPlanData {
  entrance: string;
  targetRoom: string;
  steps: NavStepData[];
  estimatedWalkMin: number; // 0 表示没有可靠步行时长
}

export default class HospitalNavSkill {
  public async getIndoorRoute(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    const hospital: string = argv.length > 0 ? argv[0].trim() : '';
    const building: string = argv.length > 1 ? argv[1].trim() : '';
    const floor: string = argv.length > 2 ? argv[2].trim() : '';
    const room: string = argv.length > 3 ? argv[3].trim() : '';
    const targetType: string = argv.length > 4 && argv[4].trim().length > 0 ? argv[4].trim() : 'clinic';
    if (hospital.length === 0) {
      await this.fail(info, 'ERR_INVALID_PARAMS', 'hospital is empty', '请先确认要去的医院');
      return;
    }
    if (targetType !== 'pharmacy' && (building.length === 0 || floor.length === 0 || room.length === 0)) {
      await this.fail(info, 'ERR_NEED_CLARIFICATION', 'clinic location is incomplete',
        '还需要确认门诊楼、楼层和诊室');
      return;
    }
    try {
      const plan: NavPlanData = targetType === 'pharmacy'
        ? HospitalNavSkill.pharmacyRoute()
        : HospitalNavSkill.clinicRoute(building, floor, room);
      const data: Record<string, Object> = {
        'navPlan': plan,
        'dataSource': 'TEMPLATE',
        'verificationStatus': 'ONSITE_CONFIRMATION_REQUIRED',
        'speech': `以下是院内引导模板，不是${hospital}的实时地图。进入医院后，请先按现场导视或向导诊台确认。` +
          `第一步：${plan.steps[0].instruction}`
      };
      const payload: Record<string, Object> = {
        'type': 'result',
        'status': 'success',
        'data': data
      };
      await this.report(info, { code: 0, result: payload });
    } catch (e) {
      const err = e as Error;
      await this.fail(info, 'ERR_INTERNAL', err.message, '暂时没有该医院的院内路线，请咨询导医台');
    }
  }

  private static step(order: number, instruction: string, landmark: string): NavStepData {
    const s: NavStepData = { order: order, instruction: instruction, landmark: landmark };
    return s;
  }

  private static clinicRoute(building: string, floor: string, room: string): NavPlanData {
    const steps: NavStepData[] = [];
    steps.push(HospitalNavSkill.step(1, `进入${building}后，先向导诊台核对${floor}${room}是否正确`, '导诊台或服务台'));
    steps.push(HospitalNavSkill.step(2, `按现场导视牌前往${floor}；行动不便时询问无障碍路线`, '楼层与科室导视牌'));
    steps.push(HospitalNavSkill.step(3, `到${floor}后，按门牌和叫号屏确认${room}，再到候诊区等候`, '门牌、叫号屏或导诊人员'));
    const plan: NavPlanData = {
      entrance: `${building}入口（请以现场导视为准）`,
      targetRoom: `${building}${floor}${room}（待现场确认）`,
      steps: steps,
      estimatedWalkMin: 0
    };
    return plan;
  }

  private static pharmacyRoute(): NavPlanData {
    const steps: NavStepData[] = [
      HospitalNavSkill.step(1, '先向导诊台确认缴费处和药房的位置', '导诊台或服务台'),
      HospitalNavSkill.step(2, '按医院现场导视前往缴费处或药房', '缴费、药房导视牌'),
      HospitalNavSkill.step(3, '取药后在窗口前核对药名和数量，有疑问立即询问工作人员', '药房窗口')
    ];
    const plan: NavPlanData = {
      entrance: '医院入口（请以现场导视为准）',
      targetRoom: '药房（待导诊台确认）',
      steps: steps,
      estimatedWalkMin: 0
    };
    return plan;
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
      console.error(`[HospitalNavSkill] report failed: ${err.code}, ${err.message}`);
    }
  }
}
