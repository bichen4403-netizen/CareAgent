/**
 * 智护同行 - 医院检索（经网关调用高德 POI 搜索）
 *
 * 老人常说“第一人民医院”“中医院”，同名医院各地都有。
 * 接入网关后，按用户当前位置检索附近最匹配的医院，拿到真实全称、地址和坐标，
 * 出行路线据此计算；未接入时保持用户原话中的名称，地址标注为演示。
 */

import { DataSourceType } from '../core/AgentTypes';
import { BackendClient } from './BackendClient';

export interface HospitalInfo {
  name: string;
  address: string;
  lng: number;
  lat: number;
  city: string;
  source: DataSourceType;
}

export class HospitalService {

  static async search(keyword: string, nearLng: number, nearLat: number): Promise<HospitalInfo | null> {
    if (keyword.trim().length === 0) {
      return null;
    }
    const query: Record<string, string> = { 'keyword': keyword.trim() };
    if (nearLng !== 0 && nearLat !== 0) {
      query['lng'] = `${nearLng}`;
      query['lat'] = `${nearLat}`;
    }
    const obj: Record<string, Object> | null = await BackendClient.getJson('/v1/hospital/search', query);
    if (obj === null) {
      return null;
    }
    const name: string = BackendClient.str(obj, 'name');
    const lng: number = BackendClient.num(obj, 'lng', 0);
    const lat: number = BackendClient.num(obj, 'lat', 0);
    if (name.length === 0 || lng === 0 || lat === 0) {
      return null;
    }
    const info: HospitalInfo = {
      name: name,
      address: BackendClient.str(obj, 'address'),
      lng: lng,
      lat: lat,
      city: BackendClient.str(obj, 'city'),
      source: DataSourceType.REALTIME_API
    };
    return info;
  }
}
