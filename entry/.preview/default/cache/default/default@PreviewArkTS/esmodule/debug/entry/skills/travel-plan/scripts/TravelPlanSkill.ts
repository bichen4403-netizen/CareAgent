import scriptManager from "@ohos:app.ability.scriptManager";
import type { BusinessError } from "@ohos:base";
import type { TravelPlan } from '../../../src/main/ets/core/AgentTypes';
import { MockDataSource } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/MockDataSource";
import { TravelService } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/TravelService";
import type { DrivingResult } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/TravelService";
/** 将路线时长与出发时间计算能力暴露给系统智能体。 */
export default class TravelPlanSkill {
    public async planTrip(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
        const originLng: number = argv.length > 0 ? Number(argv[0]) : 0;
        const originLat: number = argv.length > 1 ? Number(argv[1]) : 0;
        const originAddress: string = argv.length > 2 ? argv[2].trim() : '当前位置';
        const destAddress: string = argv.length > 3 ? argv[3].trim() : '';
        const visitTime: string = argv.length > 4 ? argv[4].trim() : '';
        const weather: string = argv.length > 5 ? argv[5].trim() : '未知';
        if (destAddress.length === 0 || visitTime.length === 0) {
            await this.fail(info, 'ERR_INVALID_PARAMS', 'destination or visitTime is empty', '还需要确认医院地址和就诊时间');
            return;
        }
        try {
            const driving: DrivingResult = await TravelService.getDrivingByAddress(originLng, originLat, destAddress);
            let bufferMin: number = 10;
            if (weather.indexOf('雨') >= 0 || weather.indexOf('雪') >= 0 ||
                driving.trafficLevel === '拥堵') {
                bufferMin = 25;
            }
            const departTime: string = MockDataSource.minusMinutes(visitTime, driving.durationMin + bufferMin + 15);
            const suggestion: string = bufferMin >= 25
                ? '天气或路况可能影响行程，已经为您多留出时间'
                : '路况正常，按建议时间出发即可';
            const plan: TravelPlan = {
                originAddress: originAddress,
                destAddress: destAddress,
                departTime: departTime,
                durationMin: driving.durationMin,
                distanceKm: driving.distanceKm,
                trafficLevel: driving.trafficLevel,
                weather: weather,
                bufferMin: bufferMin,
                suggestion: suggestion
            };
            const data: Record<string, Object> = {
                'travelPlan': plan,
                'speech': `建议您${departTime}出发，车程大约${driving.durationMin}分钟。${suggestion}`
            };
            const payload: Record<string, Object> = {
                'type': 'result',
                'status': 'success',
                'data': data
            };
            await this.report(info, { code: 0, result: payload });
        }
        catch (e) {
            const err = e as Error;
            await this.fail(info, 'ERR_INTERNAL', err.message, '暂时没能生成出行方案，请稍后再试');
        }
    }
    private async fail(info: scriptManager.ArkTSScriptInfo, errCode: string, errMsg: string, suggestion: string): Promise<void> {
        await this.report(info, {
            code: -1,
            result: {
                'type': 'result', 'status': 'failed', 'errCode': errCode,
                'errMsg': errMsg, 'suggestion': suggestion
            }
        });
    }
    private async report(info: scriptManager.ArkTSScriptInfo, result: scriptManager.ExecuteResult): Promise<void> {
        try {
            await scriptManager.completeArkTSScriptInApp(info.context, info.requestCode, result);
        }
        catch (e) {
            const err = e as BusinessError;
            console.error(`[TravelPlanSkill] report failed: ${err.code}, ${err.message}`);
        }
    }
}
