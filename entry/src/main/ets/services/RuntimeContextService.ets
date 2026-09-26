/**
 * 智护同行 - 运行时上下文
 * 每次处理用户请求前采集一次：当前位置（含城市）、当前天气、时间。
 * 定位与天气都有缓存和兜底，不会因为网络或权限问题卡住对话。
 */

import { common } from '@kit.AbilityKit';
import { RuntimeContext } from '../core/AgentTypes';
import { ContextStore } from '../core/ContextStore';
import { LocationService, LocationResult } from './LocationService';
import { WeatherService, WeatherInfo } from './WeatherService';

export class RuntimeContextService {

  /**
   * @param allowLocationPrompt 为 true 时，未授权会弹出一次位置授权框（首次规划时）
   */
  static async build(ctx: common.UIAbilityContext | null, allowLocationPrompt: boolean): Promise<RuntimeContext> {
    const homeAddress: string = ContextStore.getInstance().getProfile().homeAddress;
    const loc: LocationResult = await LocationService.getCurrent(ctx, allowLocationPrompt, homeAddress);
    const weather: WeatherInfo = await WeatherService.getCurrent(loc.lng, loc.lat);
    const rt: RuntimeContext = {
      currentLat: loc.lat,
      currentLng: loc.lng,
      currentAddress: loc.address,
      cityName: loc.city.length > 0 ? loc.city : weather.city,
      locationSource: loc.source,
      nowTs: Date.now(),
      weather: weather.weather,
      weatherSource: weather.source,
      trafficLevel: '未知'
    };
    return rt;
  }
}
