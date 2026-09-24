/**
 * 智护同行 - 官方渠道跳转
 *
 * 由于医院核心业务（挂号、缴费）需在官方渠道完成，本服务负责：
 *   1. 根据医院名称、地址、所在城市选择合适的官方渠道
 *   2. 优先尝试 App 深链，失败再打开官方网页
 *   3. 用户回到本 App 后，由页面询问“挂上了吗？”再开启提醒
 *
 * deepLink 为示例 scheme，正式接入需以各渠道官方文档为准；官方网页地址可直接使用。
 */

import { common } from '@kit.AbilityKit';

export interface OfficialChannel {
  name: string;
  deepLink: string;   // 为空表示只走网页
  webUrl: string;
  hint: string;       // 给老人看的一句话说明
}

interface RegionChannel {
  keywords: string[];
  channel: OfficialChannel;
}

const NATIONAL: OfficialChannel = {
  name: '国家政务服务平台',
  deepLink: '',
  webUrl: 'https://www.gjzwfw.gov.cn',
  hint: '在“国家政务服务平台”里找到该医院的预约挂号入口'
};

const REGION_CHANNELS: RegionChannel[] = [
  {
    keywords: ['北京'],
    channel: { name: '京医通', deepLink: 'jingyitong://', webUrl: 'https://www.jingyitong.cn', hint: '在“京医通”里确认挂号' }
  },
  {
    keywords: ['浙江', '杭州', '宁波', '温州', '绍兴', '嘉兴', '湖州', '金华', '台州', '丽水', '衢州', '舟山', '浙一', '浙二'],
    channel: { name: '浙里办', deepLink: 'zlb://', webUrl: 'https://www.zjzwfw.gov.cn', hint: '在“浙里办”搜索“挂号”确认' }
  },
  {
    keywords: ['上海'],
    channel: { name: '随申办', deepLink: 'suishenban://', webUrl: 'https://zwdt.sh.gov.cn', hint: '在“随申办”找到“医疗付费一件事”确认' }
  },
  {
    keywords: ['广东', '广州', '深圳', '佛山', '东莞', '珠海'],
    channel: { name: '粤省事', deepLink: '', webUrl: 'https://www.gdzwfw.gov.cn', hint: '在“粤省事”搜索“预约挂号”确认' }
  },
  {
    keywords: ['江苏', '南京', '苏州', '无锡', '常州'],
    channel: { name: '苏服办', deepLink: '', webUrl: 'https://www.jszwfw.gov.cn', hint: '在“苏服办”搜索“预约挂号”确认' }
  }
];

export class OfficialChannelRegistry {
  /** hintText 可以是医院名 + 地址 + 城市的拼接，命中任一关键词即选用对应地区渠道 */
  static resolve(hintText: string): OfficialChannel {
    for (let i = 0; i < REGION_CHANNELS.length; i++) {
      const kws: string[] = REGION_CHANNELS[i].keywords;
      for (let j = 0; j < kws.length; j++) {
        if (hintText.indexOf(kws[j]) >= 0) {
          return REGION_CHANNELS[i].channel;
        }
      }
    }
    return NATIONAL;
  }

  /** 按渠道名称找回渠道（行程里只保存了名称） */
  static byName(name: string, fallbackHint: string): OfficialChannel {
    if (name === NATIONAL.name) {
      return NATIONAL;
    }
    for (let i = 0; i < REGION_CHANNELS.length; i++) {
      if (REGION_CHANNELS[i].channel.name === name) {
        return REGION_CHANNELS[i].channel;
      }
    }
    return OfficialChannelRegistry.resolve(fallbackHint);
  }
}

export class AppLinkService {
  /**
   * 打开官方渠道：先试深链，失败再开网页。
   * 返回 'app' / 'web' / 'none'，调用方据此提示用户。
   */
  static async openChannel(ctx: common.UIAbilityContext, channel: OfficialChannel): Promise<string> {
    if (channel.deepLink.length > 0) {
      try {
        await ctx.openLink(channel.deepLink, { appLinkingOnly: false });
        return 'app';
      } catch (e) {
        console.warn(`[AppLink] deep link failed, fallback to web: ${e}`);
      }
    }
    try {
      await ctx.openLink(channel.webUrl, { appLinkingOnly: false });
      return 'web';
    } catch (e) {
      console.error(`[AppLink] web open failed: ${e}`);
      return 'none';
    }
  }
}
