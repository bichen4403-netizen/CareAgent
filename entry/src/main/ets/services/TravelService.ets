/**
 * 智护同行 - 出行路线服务
 *
 * 经网关调用高德驾车路线：已知医院坐标时直接算路，否则由网关先做地理编码。
 * 未接入网关或调用失败时，按直线距离估算（已知坐标）或给出演示车程，并标注来源。
 * 第三方地图密钥只放在网关，客户端不保存任何密钥。
 */

import { DataSourceType } from '../core/AgentTypes';
import { BackendClient } from './BackendClient';

export interface DrivingResult {
  durationMin: number;
  distanceKm: number;
  trafficLevel: string;
  dataSource: DataSourceType;
  provider: string;
}

export class TravelService {

  static async getDriving(originLng: number, originLat: number, destAddress: string,
    destLng: number, destLat: number): Promise<DrivingResult> {
    const body: Record<string, Object> = {
      'origin_lng': originLng,
      'origin_lat': originLat,
      'dest_address': destAddress,
      'mode': 'driving'
    };
    if (destLng !== 0 && destLat !== 0) {
      body['dest_lng'] = destLng;
      body['dest_lat'] = destLat;
    }
    const obj: Record<string, Object> | null = await BackendClient.postJson('/v1/travel/route', body);
    if (obj !== null) {
      const duration: number = BackendClient.num(obj, 'duration_min', 0);
      if (duration > 0) {
        const source: string = BackendClient.str(obj, 'data_source');
        const result: DrivingResult = {
          durationMin: Math.round(duration),
          distanceKm: BackendClient.num(obj, 'distance_km', 0),
          trafficLevel: BackendClient.str(obj, 'traffic_level').length > 0 ? BackendClient.str(obj, 'traffic_level') : '未知',
          dataSource: source === 'REALTIME_API' ? DataSourceType.REALTIME_API : DataSourceType.FALLBACK,
          provider: BackendClient.str(obj, 'provider')
        };
        return result;
      }
    }
    return TravelService.estimate(originLng, originLat, destLng, destLat);
  }

  /** 离线估算：已知两端坐标时按直线距离 ×1.4 绕行系数、城市平均 25km/h 估算；否则给演示值 */
  static estimate(originLng: number, originLat: number, destLng: number, destLat: number): DrivingResult {
    if (destLng !== 0 && destLat !== 0 && originLng !== 0 && originLat !== 0) {
      const km: number = TravelService.haversineKm(originLat, originLng, destLat, destLng) * 1.4;
      const result: DrivingResult = {
        durationMin: Math.max(8, Math.round(km / 25 * 60) + 5),
        distanceKm: Math.round(km * 10) / 10,
        trafficLevel: '未知',
        dataSource: DataSourceType.LOCAL_COMPUTED,
        provider: 'estimate'
      };
      return result;
    }
    const demo: DrivingResult = {
      durationMin: 28,
      distanceKm: 9.6,
      trafficLevel: '缓行',
      dataSource: DataSourceType.DEMO,
      provider: 'demo'
    };
    return demo;
  }

  private static haversineKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const toRad: number = Math.PI / 180;
    const dLat: number = (lat2 - lat1) * toRad;
    const dLng: number = (lng2 - lng1) * toRad;
    const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }
}
