/**
 * 后端网关配置。
 *
 * DevEco 模拟器访问电脑本机通常使用 http://10.0.2.2:8000；
 * 真机调试请改成电脑在同一局域网中的地址，例如 http://192.168.1.8:8000。
 * 正式发布必须使用 HTTPS 域名。
 */
export class BackendConfig {
  static readonly BASE_URL: string = '';

  static enabled(): boolean {
    return BackendConfig.BASE_URL.length > 0;
  }
}
