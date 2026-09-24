import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';

/**
 * 上传到小艺开放平台的 Skill 必须自包含：不 import App 内 src/main/ets 的任何文件。
 *
 * 车程来源：
 *   - GATEWAY_BASE_URL 已配置：调用自建网关 /v1/travel/route（高德实时路线），失败如实返回 ERR_INTERNAL
 *   - 未配置：按演示值估算，并在建议与播报中明确说明是“估算”，不冒充实时路况
 * 出发时间公式与 SKILL.md 保持一致：就诊时间 − 车程 − 天气/路况缓冲 − 15 分钟取号排队。
 */
const GATEWAY_BASE_URL: string = '';
/** 与 backend/.env 的 APP_ACCESS_TOKEN 保持一致；网关未设置访问令牌时留空 */
const GATEWAY_APP_TOKEN: string = '';

interface TravelPlanData {
  originAddress: string;
  destAddress: string;
  departTime: string;
  durationMin: number;
  distanceKm: number;
  trafficLevel: string;
  weather: string;
  bufferMin: number;
  suggestion: string;
}

interface RouteEstimate {
  durationMin: number;
  distanceKm: number;
  trafficLevel: string;
  estimated: boolean;
}

export default class TravelPlanSkill {
  public async planTrip(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    const originLng: number = argv.length > 0 ? Number(argv[0]) : 0;
    const originLat: number = argv.length > 1 ? Number(argv[1]) : 0;
    const originAddress: string = argv.length > 2 && argv[2].trim().length > 0 ? argv[2].trim() : '当前位置';
    const destAddress: string = argv.length > 3 ? argv[3].trim() : '';
    const visitTime: string = argv.length > 4 ? argv[4].trim() : '';
    const weather: string = argv.length > 5 && argv[5].trim().length > 0 ? argv[5].trim() : '未知';
    if (destAddress.length === 0 || !/^[0-9]{2}:[0-9]{2}$/.test(visitTime)) {
      await this.fail(info, 'ERR_INVALID_PARAMS', 'destination or visitTime is empty',
        '还需要确认医院地址和就诊时间');
      return;
    }
    try {
      const route: RouteEstimate | null = await TravelPlanSkill.queryRoute(
        isFinite(originLng) ? originLng : 0, isFinite(originLat) ? originLat : 0, destAddress);
      if (route === null) {
        await this.fail(info, 'ERR_INTERNAL', 'driving route unavailable', '暂时没能查到路况，请稍后再试');
        return;
      }
      const badWeather: boolean = /雨|雪|雾|冰雹|台风/.test(weather);
      const bufferMin: number = (badWeather || route.trafficLevel === '拥堵') ? 25 : 10;
      const departTime: string = TravelPlanSkill.minusMinutes(visitTime, route.durationMin + bufferMin + 15);
      let suggestion: string = bufferMin >= 25
        ? '天气或路况可能影响行程，已经为您多留出时间，建议打车'
        : '路况正常，按建议时间出发即可';
      if (route.estimated) {
        suggestion += '（车程为演示估算，出发前请以实际路况为准）';
      }
      const plan: TravelPlanData = {
        originAddress: originAddress,
        destAddress: destAddress,
        departTime: departTime,
        durationMin: route.durationMin,
        distanceKm: route.distanceKm,
        trafficLevel: route.trafficLevel,
        weather: weather,
        bufferMin: bufferMin,
        suggestion: suggestion
      };
      const estimateNote: string = route.estimated ? '（估算）' : '';
      const data: Record<string, Object> = {
        'travelPlan': plan,
        'speech': `建议您${departTime}出发，车程大约${route.durationMin}分钟${estimateNote}。` +
          (bufferMin >= 25 ? '天气或路况不太好，已经多留出时间。' : '按时出发就能赶上看诊。')
      };
      const payload: Record<string, Object> = {
        'type': 'result',
        'status': 'success',
        'data': data
      };
      await this.report(info, { code: 0, result: payload });
    } catch (e) {
      const err = e as Error;
      await this.fail(info, 'ERR_INTERNAL', err.message, '暂时没能生成出行方案，请稍后再试');
    }
  }

  /** 网关已配置时查实时路线；未配置时返回演示估算；网关失败返回 null */
  private static async queryRoute(originLng: number, originLat: number, destAddress: string): Promise<RouteEstimate | null> {
    if (GATEWAY_BASE_URL.length === 0) {
      const demo: RouteEstimate = { durationMin: 28, distanceKm: 9.6, trafficLevel: '缓行', estimated: true };
      return demo;
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      const body: Record<string, Object> = {
        'origin_lng': originLng,
        'origin_lat': originLat,
        'dest_address': destAddress,
        'mode': 'driving'
      };
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      if (GATEWAY_APP_TOKEN.length > 0) {
        headers['X-App-Token'] = GATEWAY_APP_TOKEN;
      }
      const resp: http.HttpResponse = await req.request(`${GATEWAY_BASE_URL.replace(/\/+$/, '')}/v1/travel/route`, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(body),
        connectTimeout: 5000,
        readTimeout: 8000
      });
      if (resp.responseCode !== 200) {
        return null;
      }
      const obj: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
      const duration: Object | undefined = obj['duration_min'];
      const distance: Object | undefined = obj['distance_km'];
      const traffic: Object | undefined = obj['traffic_level'];
      const source: Object | undefined = obj['data_source'];
      if (typeof duration !== 'number' || duration <= 0) {
        return null;
      }
      const level: string = (traffic === '畅通' || traffic === '缓行' || traffic === '拥堵') ? traffic as string : '缓行';
      const result: RouteEstimate = {
        durationMin: Math.round(duration),
        distanceKm: typeof distance === 'number' ? distance : 0,
        trafficLevel: level,
        estimated: source !== 'REALTIME_API'
      };
      return result;
    } catch (e) {
      console.error(`[TravelPlanSkill] route query failed: ${e}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  /** HH:mm 减去若干分钟，最早 00:00 */
  private static minusMinutes(hhmm: string, minutes: number): string {
    const parts: string[] = hhmm.split(':');
    const total: number = Math.max(0, Number(parts[0]) * 60 + Number(parts[1]) - minutes);
    const h: number = Math.floor(total / 60);
    const m: number = total % 60;
    return `${h < 10 ? '0' : ''}${h}:${m < 10 ? '0' : ''}${m}`;
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
      console.error(`[TravelPlanSkill] report failed: ${err.code}, ${err.message}`);
    }
  }
}
