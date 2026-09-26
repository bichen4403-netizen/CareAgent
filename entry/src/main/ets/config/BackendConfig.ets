/**
 * 后端网关配置。
 *
 * BASE_URL 留空 = 离线演示模式（离线规则理解 + 演示数据），答辩现场断网也能完整跑通。
 * 填写后：大模型（DeepSeek）、天气、路线、医院检索全部经由 backend/ 网关，客户端不保存任何第三方密钥。
 *
 * 当前 DevEco 模拟器通过电脑 WLAN 地址访问本机网关。网络切换后请更新此地址；
 * 真机调试同样使用电脑在同一局域网中的地址。
 * 正式发布必须使用 HTTPS 域名。
 */
export class BackendConfig {
  static readonly BASE_URL: string = 'http://172.30.105.23:8000';

  /**
   * 与 backend/.env 中的 APP_ACCESS_TOKEN 保持一致；后端未设置时这里留空。
   * 它只能防止网关地址被随手滥用，不能当作真正的用户鉴权。
   */
  static readonly APP_TOKEN: string = '';

  static enabled(): boolean {
    return BackendConfig.BASE_URL.trim().length > 0;
  }

  /** 去掉末尾斜杠的网关地址 */
  static baseUrl(): string {
    return BackendConfig.BASE_URL.trim().replace(/\/+$/, '');
  }

  static headers(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (BackendConfig.APP_TOKEN.length > 0) {
      h['X-App-Token'] = BackendConfig.APP_TOKEN;
    }
    return h;
  }
}
