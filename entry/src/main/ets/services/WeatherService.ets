/**
 * 智护同行 - 天气服务
 *
 * ⚠️ 配置说明：真实天气请求应由受控后端代理，不要把高德 Web 服务 Key
 * 写入客户端源码。当前 Key 留空，自动使用 Mock 数据（固定返回"小雨"），
 * 保证 Demo 离线也能演示。
 *
 * 高德天气 API 用的是"城市编码"（adcode）而不是经纬度，
 * 常见城市编码可以在这里查：https://lbs.amap.com/api/webservice/download
 * 下面默认写的是杭州（330100），换成你所在城市的编码即可。
 */

import { http } from '@kit.NetworkKit';
import { DataSourceType } from '../core/AgentTypes';

// 客户端不保存 Web 服务密钥。留空时使用 Mock；真实服务应由受控后端代理。
const AMAP_KEY: string = '';
const DEFAULT_CITY_CODE: string = '110000';  // 默认北京，换成你的城市编码

export interface WeatherProvider {
  getWeather(cityCode: string): Promise<WeatherResult>;
}

export interface WeatherResult {
  weather: string;
  dataSource: DataSourceType;
  provider: string;
  updatedAt: number;
}

/** 通过自建 FastAPI 网关读取天气，客户端不接触第三方 Key。 */
export class BackendWeatherProvider implements WeatherProvider {
  private baseUrl: string;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl.replace(/\/$/, '');
  }

  async getWeather(cityCode: string): Promise<WeatherResult> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const url: string = `${this.baseUrl}/v1/weather?city_code=${encodeURIComponent(cityCode)}`;
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`gateway weather HTTP ${resp.responseCode}`);
      }
      const obj: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
      return {
        weather: obj['weather'] as string,
        dataSource: obj['data_source'] as DataSourceType,
        provider: obj['provider'] as string,
        updatedAt: obj['updated_at'] as number
      };
    } finally {
      req.destroy();
    }
  }
}

/** 真实天气：调用高德天气 API */
export class AmapWeatherProvider implements WeatherProvider {
  async getWeather(cityCode: string): Promise<WeatherResult> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const url: string =
        `https://restapi.amap.com/v3/weather/weatherInfo?city=${cityCode}&key=${AMAP_KEY}&extensions=base`;
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      });

      if (resp.responseCode !== 200) {
        throw new Error(`weather HTTP ${resp.responseCode}`);
      }

      const raw: string = resp.result as string;
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const lives = obj['lives'] as Array<Record<string, string>>;
      if (lives !== undefined && lives.length > 0) {
        return {
          weather: lives[0]['weather'],
          dataSource: DataSourceType.REALTIME_API,
          provider: 'amap',
          updatedAt: Date.now()
        };
      }
      throw new Error('weather empty result');
    } finally {
      req.destroy();
    }
  }
}

/** 离线兜底：固定返回小雨，方便演示"天气影响出行"的场景 */
export class MockWeatherProvider implements WeatherProvider {
  async getWeather(cityCode: string): Promise<WeatherResult> {
    return {
      weather: '小雨',
      dataSource: DataSourceType.DEMO,
      provider: 'offline-demo',
      updatedAt: Date.now()
    };
  }
}

export class WeatherService {
  private static provider: WeatherProvider =
    AMAP_KEY.length > 0 ? new AmapWeatherProvider() : new MockWeatherProvider();

  static useBackend(baseUrl: string): void {
    if (baseUrl.length > 0) {
      WeatherService.provider = new BackendWeatherProvider(baseUrl);
    }
  }

  static async getWeather(cityCode: string = DEFAULT_CITY_CODE): Promise<WeatherResult> {
    try {
      return await WeatherService.provider.getWeather(cityCode);
    } catch (e) {
      console.error(`[WeatherService] failed, fallback to mock: ${e}`);
      const fallback: MockWeatherProvider = new MockWeatherProvider();
      return await fallback.getWeather(cityCode);
    }
  }
}
