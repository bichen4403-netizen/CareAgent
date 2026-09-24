/**
 * 智护同行 - 天气服务
 *
 * 经网关查询高德天气：按坐标定位城市，就诊日在 3 天内给出预报，更远的日期如实返回“暂无预报”。
 * 未接入网关时返回演示天气（小雨），出行方案会标注“演示数据”。
 */

import { DataSourceType } from '../core/AgentTypes';
import { BackendClient } from './BackendClient';

export interface WeatherInfo {
  weather: string;
  city: string;
  isForecast: boolean;
  source: DataSourceType;
}

const DEMO_WEATHER: string = '小雨';
const CACHE_MS: number = 10 * 60 * 1000;

export class WeatherService {
  private static cache: Map<string, WeatherInfo> = new Map<string, WeatherInfo>();
  private static cacheAt: Map<string, number> = new Map<string, number>();

  /** 当前天气 */
  static async getCurrent(lng: number, lat: number): Promise<WeatherInfo> {
    return await WeatherService.query(lng, lat, '');
  }

  /** 指定日期（YYYY-MM-DD）的天气预报 */
  static async getForDate(lng: number, lat: number, date: string): Promise<WeatherInfo> {
    return await WeatherService.query(lng, lat, date);
  }

  static demo(): WeatherInfo {
    const w: WeatherInfo = { weather: DEMO_WEATHER, city: '', isForecast: false, source: DataSourceType.DEMO };
    return w;
  }

  private static async query(lng: number, lat: number, date: string): Promise<WeatherInfo> {
    const key: string = `${lng.toFixed(2)},${lat.toFixed(2)},${date}`;
    const cached: WeatherInfo | undefined = WeatherService.cache.get(key);
    const cachedAt: number | undefined = WeatherService.cacheAt.get(key);
    if (cached !== undefined && cachedAt !== undefined && Date.now() - cachedAt < CACHE_MS) {
      return cached;
    }
    const query: Record<string, string> = { 'lng': `${lng}`, 'lat': `${lat}` };
    if (date.length > 0) {
      query['date'] = date;
    }
    const obj: Record<string, Object> | null = await BackendClient.getJson('/v1/weather', query);
    if (obj === null) {
      return WeatherService.demo();
    }
    const weather: string = BackendClient.str(obj, 'weather');
    if (weather.length === 0) {
      return WeatherService.demo();
    }
    const source: string = BackendClient.str(obj, 'data_source');
    const info: WeatherInfo = {
      weather: weather,
      city: BackendClient.str(obj, 'city'),
      isForecast: obj['is_forecast'] === true,
      source: source === 'REALTIME_API' ? DataSourceType.REALTIME_API : DataSourceType.FALLBACK
    };
    WeatherService.cache.set(key, info);
    WeatherService.cacheAt.set(key, Date.now());
    return info;
  }
}
