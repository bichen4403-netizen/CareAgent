/**
 * 智护同行 - 网关请求封装
 * 天气、路线、医院检索共用：统一超时、统一带访问令牌、统一容错解析。
 * 网关未配置或请求失败时返回 null，由调用方退回演示数据。
 */

import { http } from '@kit.NetworkKit';
import { BackendConfig } from '../config/BackendConfig';

export class BackendClient {

  static async getJson(path: string, query: Record<string, string>): Promise<Record<string, Object> | null> {
    if (!BackendConfig.enabled()) {
      return null;
    }
    const parts: string[] = [];
    const keys: string[] = Object.keys(query);
    for (let i = 0; i < keys.length; i++) {
      const v: string | undefined = query[keys[i]];
      if (v !== undefined && v.length > 0) {
        parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(v)}`);
      }
    }
    const url: string = `${BackendConfig.baseUrl()}${path}${parts.length > 0 ? '?' + parts.join('&') : ''}`;
    return await BackendClient.send(url, http.RequestMethod.GET, '');
  }

  static async postJson(path: string, body: Record<string, Object>): Promise<Record<string, Object> | null> {
    if (!BackendConfig.enabled()) {
      return null;
    }
    return await BackendClient.send(`${BackendConfig.baseUrl()}${path}`, http.RequestMethod.POST,
      JSON.stringify(body));
  }

  private static async send(url: string, method: http.RequestMethod, body: string): Promise<Record<string, Object> | null> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: BackendConfig.headers(),
        connectTimeout: 5000,
        readTimeout: 8000
      };
      if (body.length > 0) {
        options.extraData = body;
      }
      const resp: http.HttpResponse = await req.request(url, options);
      if (resp.responseCode !== 200) {
        console.warn(`[Backend] ${url} -> HTTP ${resp.responseCode}`);
        return null;
      }
      const v: Object = JSON.parse(resp.result as string) as Object;
      if (v === null || typeof v !== 'object' || Array.isArray(v)) {
        return null;
      }
      return v as Record<string, Object>;
    } catch (e) {
      console.warn(`[Backend] ${url} failed: ${e}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  static str(obj: Record<string, Object>, key: string): string {
    const v: Object | undefined = obj[key];
    return typeof v === 'string' ? v : '';
  }

  static num(obj: Record<string, Object>, key: string, def: number): number {
    const v: Object | undefined = obj[key];
    if (typeof v === 'number' && isFinite(v)) {
      return v;
    }
    if (typeof v === 'string' && v.length > 0) {
      const n: number = Number(v);
      return isFinite(n) ? n : def;
    }
    return def;
  }
}
