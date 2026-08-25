/**
 * 智护同行 - 官方挂号渠道跳转
 *
 * 核心原则：智护同行不越权代替医院完成挂号，只做到"方案准备好、
 * 一键跳转官方渠道"，最后一步确认权始终在官方系统和用户手里。
 * 这是所有正规互联网医疗产品（微医/京医通类）实际采用的合规模式。
 *
 * ⚠️ 需要你手动维护的部分：
 * OFFICIAL_CHANNELS 这张表按医院名称关键词匹配对应的官方渠道，
 * 目前只填了几个示例（京医通/浙里办），你需要根据 demo 要用的
 * 目标医院，把它对应的官方挂号渠道（医院自己的小程序，或当地
 * 政务健康平台）补充进去。查不到具体 scheme 的话，先用该医院
 * 官网/官方小程序的 H5 链接作为兜底，同样能跳转，只是体验上
 * 不如原生 App 唤起顺滑。
 *
 * ⚠️ 跳转 API 说明：
 * HarmonyOS 的 AppLinking / 唤起第三方应用能力，不同 SDK 版本
 * 接口可能有差异，本文件把跳转逻辑收敛在 openLink() 一处，
 * 请对照本地 DevEco 版本的 @kit.AbilityKit 文档核实具体调用方式。
 */

import { common } from '@kit.AbilityKit';

/** 一个官方挂号渠道的接入信息 */
export interface OfficialChannel {
  name: string;           // 渠道名称，展示给用户看，如"京医通"
  deepLink: string;       // 优先尝试的 App 深链接（scheme），能直接唤起原生 App 到对应页面最好
  fallbackUrl: string;    // 深链接失败时的兜底方案，通常是 H5 页面或小程序链接
  hint: string;           // 提示用户在官方渠道里大概要做什么，降低老人的操作焦虑
}

/**
 * 医院名称关键词 → 官方渠道映射
 * 匹配规则：医院名称包含 key 就命中，请按你实际演示的医院补充
 */
const OFFICIAL_CHANNELS: Record<string, OfficialChannel> = {
  '北京': {
    name: '京医通',
    deepLink: 'jingyitong://appointment',   // 示例 scheme，需以京医通官方文档为准
    fallbackUrl: 'https://www.bjjyt.com.cn',
    hint: '打开京医通后，搜索医院和科室，选择我们刚才商量好的这个时间段'
  },
  '浙江': {
    name: '浙里办',
    deepLink: 'zlb://healthcare/appointment',
    fallbackUrl: 'https://www.zjzwfw.gov.cn',
    hint: '打开浙里办后，找到"预约挂号"服务，选择这家医院和科室'
  },
  '上海': {
    name: '随申办',
    deepLink: 'suishenban://healthcare/appointment',
    fallbackUrl: 'https://www.shanghai.gov.cn',
    hint: '打开随申办，进入健康云板块选择医院预约'
  }
};

/** 没匹配到具体城市渠道时的通用兜底 —— 国家政务服务平台 */
const DEFAULT_CHANNEL: OfficialChannel = {
  name: '国家政务服务平台',
  deepLink: '',
  fallbackUrl: 'https://www.gjzwfw.gov.cn',
  hint: '在里面搜索"预约挂号"服务，选择对应医院完成最后确认'
};

export class OfficialChannelRegistry {
  /** 按医院名称/地址关键词查找对应的官方渠道 */
  static resolve(hospitalNameOrAddress: string): OfficialChannel {
    const keys: string[] = Object.keys(OFFICIAL_CHANNELS);
    for (let i = 0; i < keys.length; i++) {
      if (hospitalNameOrAddress.indexOf(keys[i]) >= 0) {
        return OFFICIAL_CHANNELS[keys[i]];
      }
    }
    return DEFAULT_CHANNEL;
  }
}

export class AppLinkService {
  /**
   * 跳转到官方渠道完成最后确认
   * 优先尝试 deepLink 唤起原生 App，失败（未安装/scheme 无效）则降级用 fallbackUrl 打开网页
   * @returns true 表示跳转动作已发出（不代表用户一定完成了挂号，那一步只能用户自己确认）
   */
  static async openOfficialChannel(context: common.UIAbilityContext, channel: OfficialChannel): Promise<boolean> {
    if (channel.deepLink.length > 0) {
      const ok: boolean = await AppLinkService.tryOpenLink(context, channel.deepLink);
      if (ok) {
        return true;
      }
      console.warn(`[AppLinkService] deepLink 打开失败，降级到 fallbackUrl: ${channel.fallbackUrl}`);
    }
    return await AppLinkService.tryOpenLink(context, channel.fallbackUrl);
  }

  private static async tryOpenLink(context: common.UIAbilityContext, link: string): Promise<boolean> {
    if (link.length === 0) {
      return false;
    }
    try {
      // context.openLink() 是 HarmonyOS 提供的 App Linking / 唤起第三方应用能力
      // 若本地 SDK 版本没有这个方法，这里会直接报"属性不存在"的编译错误，
      // 那种报错反而更清楚——说明需要换成你 SDK 里实际提供的唤起 API，对照
      // @kit.AbilityKit 文档替换掉这一行调用即可，其余逻辑不用动
      await context.openLink(link, { appLinkingOnly: false });
      return true;
    } catch (e) {
      console.error(`[AppLinkService] openLink failed for ${link}: ${e}`);
      return false;
    }
  }
}
