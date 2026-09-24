import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 上传到小艺开放平台的 Skill 必须自包含：不 import App 内 src/main/ets 的任何文件。
 * 院内地图暂无公开接口，路线为演示数据（dataSource 固定为 demo），
 * 生成规则与 App 内导航 Agent 一致：1 楼不需要坐电梯，取药场景走“缴费 → 药房”。
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
  estimatedWalkMin: number;
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
        'dataSource': 'demo',
        'speech': `从${plan.entrance}进去，走大约${plan.estimatedWalkMin}分钟就到${plan.targetRoom}。` +
          `一共${plan.steps.length}步，第一步：${plan.steps[0].instruction}`
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
    steps.push(HospitalNavSkill.step(1, `从医院正门进入${building}，先到一楼大厅`, '门口有导诊台，可以找工作人员帮忙'));
    steps.push(HospitalNavSkill.step(2, '在自助机上刷医保卡或身份证取号，取号后拿好小票', '大厅左手边的自助机'));
    if (floor !== '1楼') {
      steps.push(HospitalNavSkill.step(3, `坐电梯上${floor}，出电梯后看墙上的科室指示牌`, '电梯在大厅正中间，腿脚不便别走楼梯'));
    } else {
      steps.push(HospitalNavSkill.step(3, '就在一楼，顺着地上的指示线往里走', '跟着地面彩色导引线走'));
    }
    steps.push(HospitalNavSkill.step(4, `找到${room}门口，在候诊区坐下等叫号`, '门口屏幕会显示排队号'));
    const plan: NavPlanData = {
      entrance: '医院正门',
      targetRoom: `${building}${floor}${room}`,
      steps: steps,
      estimatedWalkMin: floor === '1楼' ? 5 : 8
    };
    return plan;
  }

  private static pharmacyRoute(): NavPlanData {
    const steps: NavStepData[] = [
      HospitalNavSkill.step(1, '看完医生后，先到一楼缴费窗口或自助机缴费', '门诊大厅右手边'),
      HospitalNavSkill.step(2, '缴费后到一楼西药房取药，把缴费单交给窗口', '药房门口有叫号屏'),
      HospitalNavSkill.step(3, '拿到药先在窗口前核对药名和数量，再离开', '有疑问直接问药房工作人员')
    ];
    const plan: NavPlanData = {
      entrance: '门诊大厅',
      targetRoom: '一楼西药房',
      steps: steps,
      estimatedWalkMin: 5
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
