/**
 * 智护同行 - 出行路况服务
 *
 * ⚠️ 配置说明：同 WeatherService，用同一个高德 Web服务 Key。
 * 调用高德"驾车路径规划"接口，拿到真实的车程时间、距离、路况拥堵情况。
 * 留空则自动使用 Mock 数据，保证离线也能演示。
 *
 * 经纬度格式要求："经度,纬度"，注意高德是经度在前、纬度在后，
 * 和很多其他地图服务的顺序相反，容易填反。
 */

import { http } from '@kit.NetworkKit';

const AMAP_KEY: string = '';   // 在这里粘贴你的高德 Web服务 Key（和 WeatherService 里的一样）

export interface DrivingResult {
  durationMin: number;
  distanceKm: number;
  trafficLevel: string;   // 畅通 / 缓行 / 拥堵
}

export interface TravelProvider {
  getDriving(originLng: number, originLat: number, destLng: number, destLat: number): Promise<DrivingResult>;
}

/**
 * 地址转经纬度（高德地理编码 API）
 * TravelAgent 手里只有"医院地址"这种文字，需要先转成经纬度才能查路况
 */
export class GeoCoder {
  static async geocode(address: string): Promise<[number, number] | null> {
    if (AMAP_KEY.length === 0 || address.length === 0) {
      return null;
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      const url: string =
        `https://restapi.amap.com/v3/geocode/geo?address=${encodeURIComponent(address)}&key=${AMAP_KEY}`;
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      });
      if (resp.responseCode !== 200) {
        return null;
      }
      const obj: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
      const geocodes = obj['geocodes'] as Array<Record<string, string>>;
      if (geocodes === undefined || geocodes.length === 0) {
        return null;
      }
      const location: string = geocodes[0]['location'];   // "经度,纬度"
      const parts: string[] = location.split(',');
      if (parts.length !== 2) {
        return null;
      }
      return [parseFloat(parts[0]), parseFloat(parts[1])];
    } catch (e) {
      console.error(`[GeoCoder] failed: ${e}`);
      return null;
    } finally {
      req.destroy();
    }
  }
}

/** 真实路况：调用高德驾车路径规划 API */
export class AmapTravelProvider implements TravelProvider {
  async getDriving(originLng: number, originLat: number,
                   destLng: number, destLat: number): Promise<DrivingResult> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const origin: string = `${originLng},${originLat}`;
      const dest: string = `${destLng},${destLat}`;
      // strategy=10：躲避拥堵，更贴近真实建议路线
      const url: string =
        `https://restapi.amap.com/v3/direction/driving?origin=${origin}&destination=${dest}` +
        `&extensions=base&strategy=10&key=${AMAP_KEY}`;

      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      });

      if (resp.responseCode !== 200) {
        throw new Error(`driving HTTP ${resp.responseCode}`);
      }

      const raw: string = resp.result as string;
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const route = obj['route'] as Record<string, Object>;
      const paths = route['paths'] as Array<Record<string, string>>;
      if (paths === undefined || paths.length === 0) {
        throw new Error('driving empty result');
      }

      const path: Record<string, string> = paths[0];
      const durationSec: number = parseInt(path['duration']);
      const distanceMeter: number = parseInt(path['distance']);

      return {
        durationMin: Math.round(durationSec / 60),
        distanceKm: Math.round(distanceMeter / 100) / 10,
        trafficLevel: AmapTravelProvider.estimateTrafficLevel(durationSec, distanceMeter)
      };
    } finally {
      req.destroy();
    }
  }

  /** 高德 base 版接口不直接返回拥堵等级，用平均时速粗略估算 */
  private static estimateTrafficLevel(durationSec: number, distanceMeter: number): string {
    if (durationSec <= 0) {
      return '畅通';
    }
    const speedKmh: number = (distanceMeter / 1000) / (durationSec / 3600);
    if (speedKmh >= 30) {
      return '畅通';
    }
    if (speedKmh >= 15) {
      return '缓行';
    }
    return '拥堵';
  }
}

/** 离线兜底 */
export class MockTravelProvider implements TravelProvider {
  async getDriving(originLng: number, originLat: number,
                   destLng: number, destLat: number): Promise<DrivingResult> {
    return {
      durationMin: 28,
      distanceKm: 8.6,
      trafficLevel: '缓行'
    };
  }
}

export class TravelService {
  private static provider: TravelProvider =
    AMAP_KEY.length > 0 ? new AmapTravelProvider() : new MockTravelProvider();

  static async getDriving(originLng: number, originLat: number,
                          destLng: number, destLat: number): Promise<DrivingResult> {
    try {
      return await TravelService.provider.getDriving(originLng, originLat, destLng, destLat);
    } catch (e) {
      console.error(`[TravelService] failed, fallback to mock: ${e}`);
      const fallback: MockTravelProvider = new MockTravelProvider();
      return await fallback.getDriving(originLng, originLat, destLng, destLat);
    }
  }

  /**
   * 按地址查询（TravelAgent 用这个即可，内部自动做地理编码）
   * @param originLng/originLat 起点经纬度（Index.ets 采集到的当前位置，已知不需要再编码）
   * @param destAddress 终点地址文字，如"市第一人民医院（人民路128号）"
   */
  static async getDrivingByAddress(originLng: number, originLat: number,
                                   destAddress: string): Promise<DrivingResult> {
    if (AMAP_KEY.length === 0) {
      const fallback: MockTravelProvider = new MockTravelProvider();
      return await fallback.getDriving(originLng, originLat, 0, 0);
    }
    const destCoord: [number, number] | null = await GeoCoder.geocode(destAddress);
    if (destCoord === null) {
      console.warn(`[TravelService] geocode failed for "${destAddress}", fallback to mock`);
      const fallback: MockTravelProvider = new MockTravelProvider();
      return await fallback.getDriving(originLng, originLat, 0, 0);
    }
    return TravelService.getDriving(originLng, originLat, destCoord[0], destCoord[1]);
  }
}
