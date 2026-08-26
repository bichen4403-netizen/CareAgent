import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { IndoorNavPlan } from '../../../src/main/ets/core/AgentTypes';
import { MockDataSource } from '../../../src/main/ets/services/MockDataSource';

/** 将院内诊室或药房路线能力暴露给系统智能体。 */
export default class HospitalNavSkill {
  public async getIndoorRoute(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    const hospital: string = argv.length > 0 ? argv[0].trim() : '';
    const building: string = argv.length > 1 ? argv[1].trim() : '';
    const floor: string = argv.length > 2 ? argv[2].trim() : '';
    const room: string = argv.length > 3 ? argv[3].trim() : '';
    const targetType: string = argv.length > 4 ? argv[4].trim() : 'clinic';

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
      let plan: IndoorNavPlan;
      if (targetType === 'pharmacy') {
        plan = await MockDataSource.queryPharmacyNav(hospital);
      } else {
        plan = await MockDataSource.queryIndoorNav(hospital, building, floor, room);
      }
      const data: Record<string, Object> = {
        'navPlan': plan,
        'dataSource': 'demo',
        'speech': `从${plan.entrance}进入，步行大约${plan.estimatedWalkMin}分钟到${plan.targetRoom}`
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
