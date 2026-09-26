/**
 * 智护同行 - 定位服务
 *
 * 流程：检查/申请模糊+精确位置权限 → 系统定位（5 秒超时）→ 逆地理编码得到“现在在哪”和城市名。
 * 任一步失败都退回演示坐标，并标注来源 DEMO，出行方案会提示“使用的是演示位置”。
 */

import { common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { DataSourceType } from '../core/AgentTypes';
import { PermissionHelper } from '../utils/PermissionHelper';

export interface LocationResult {
  lat: number;
  lng: number;
  address: string;
  city: string;
  source: DataSourceType;
}

/** 演示坐标（杭州市中心附近），与演示档案的“幸福小区”对应 */
const DEMO_LAT: number = 30.2741;
const DEMO_LNG: number = 120.1551;
const CACHE_MS: number = 5 * 60 * 1000;

const LOCATION_PERMISSIONS: Permissions[] = ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'];

export class LocationService {
  private static cache: LocationResult | null = null;
  private static cacheAt: number = 0;
  private static askedThisSession: boolean = false;

  static demoLocation(homeAddress: string): LocationResult {
    const r: LocationResult = {
      lat: DEMO_LAT,
      lng: DEMO_LNG,
      address: homeAddress.length > 0 ? homeAddress : '家',
      city: '',
      source: DataSourceType.DEMO
    };
    return r;
  }

  /**
   * 获取当前位置。allowPrompt=true 时，如未授权会弹出系统授权框（每次启动最多问一次）。
   */
  static async getCurrent(ctx: common.UIAbilityContext | null, allowPrompt: boolean,
    homeAddress: string): Promise<LocationResult> {
    const now: number = Date.now();
    if (LocationService.cache !== null && now - LocationService.cacheAt < CACHE_MS) {
      return LocationService.cache;
    }

    let granted: boolean = PermissionHelper.isGranted('ohos.permission.APPROXIMATELY_LOCATION');
    if (!granted && allowPrompt && ctx !== null && !LocationService.askedThisSession) {
      LocationService.askedThisSession = true;
      granted = await PermissionHelper.request(ctx, LOCATION_PERMISSIONS,
        'ohos.permission.APPROXIMATELY_LOCATION', false);
    }
    if (!granted) {
      return LocationService.demoLocation(homeAddress);
    }

    try {
      if (!geoLocationManager.isLocationEnabled()) {
        console.warn('[Location] location switch is off, use demo location');
        return LocationService.demoLocation(homeAddress);
      }
      const request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        maxAccuracy: 1000,
        timeoutMs: 5000
      };
      const loc: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(request);
      const result: LocationResult = {
        lat: loc.latitude,
        lng: loc.longitude,
        address: homeAddress.length > 0 ? `当前位置（${homeAddress}附近）` : '当前位置',
        city: '',
        source: DataSourceType.REALTIME_API
      };
      await LocationService.fillAddress(result);
      LocationService.cache = result;
      LocationService.cacheAt = now;
      return result;
    } catch (e) {
      console.warn(`[Location] locate failed, use demo location: ${e}`);
      return LocationService.demoLocation(homeAddress);
    }
  }

  /** 逆地理编码：拿到“XX路XX号”和城市名；2.5 秒内拿不到就放弃，不阻塞规划 */
  private static async fillAddress(result: LocationResult): Promise<void> {
    try {
      if (!geoLocationManager.isGeocoderAvailable()) {
        return;
      }
      const request: geoLocationManager.ReverseGeoCodeRequest = {
        latitude: result.lat,
        longitude: result.lng,
        maxItems: 1
      };
      const timeout: Promise<geoLocationManager.GeoAddress[]> =
        new Promise<geoLocationManager.GeoAddress[]>((resolve: (v: geoLocationManager.GeoAddress[]) => void) => {
          setTimeout(() => {
            resolve([]);
          }, 2500);
        });
      const list: geoLocationManager.GeoAddress[] = await Promise.race<geoLocationManager.GeoAddress[]>([
        geoLocationManager.getAddressesFromLocation(request), timeout
      ]);
      if (list.length === 0) {
        return;
      }
      const addr: geoLocationManager.GeoAddress = list[0];
      const place: string = addr.placeName !== undefined ? addr.placeName : '';
      if (place.length > 0) {
        result.address = place;
      }
      const city: string = addr.locality !== undefined ? addr.locality : '';
      result.city = city.length > 0 ? city : (addr.administrativeArea !== undefined ? addr.administrativeArea : '');
    } catch (e) {
      console.warn(`[Location] reverse geocode failed: ${e}`);
    }
  }
}
