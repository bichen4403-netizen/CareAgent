/**
 * 智护同行 - 日期工具
 *
 * 1. 所有日期都按“本地时间”构造（new Date(y, m, d)），避免 new Date('YYYY-MM-DD')
 *    被当成 UTC 解析导致东八区差 8 小时。
 * 2. parseChineseDate 负责把“明天 / 下周三 / 9月28号 / 3天后”等口语确定性地换算成日期。
 *    大模型对相对日期换算并不可靠，这一步必须由代码完成。
 * 本文件不依赖任何系统 Kit，可在 Node 环境下直接单测。
 */

/** 口语日期解析结果 */
export interface DateHint {
  /** YYYY-MM-DD，解析不出来时为空 */
  date: string;
  /** 用户给了范围但没给具体哪天，例如“下周”“过几天”，用于定制追问 */
  vague: string;
}

const CN_DIGITS: Record<string, number> = {
  '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9
};

const WEEKDAY_NUM: Record<string, number> = {
  '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
  '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7
};

const WEEKDAY_LABEL: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

export class DateUtil {
  static readonly DAY_MS: number = 24 * 3600 * 1000;

  static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** Date → YYYY-MM-DD（本地时间） */
  static formatDate(d: Date): string {
    return `${d.getFullYear()}-${DateUtil.pad2(d.getMonth() + 1)}-${DateUtil.pad2(d.getDate())}`;
  }

  static todayStr(nowTs: number): string {
    return DateUtil.formatDate(new Date(nowTs));
  }

  static dateAfter(nowTs: number, days: number): string {
    const now: Date = new Date(nowTs);
    return DateUtil.formatDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() + days));
  }

  /** 构造本地日期并校验合法性（例如 2 月 30 日返回 null） */
  static makeDate(year: number, month: number, day: number): Date | null {
    if (isNaN(year) || isNaN(month) || isNaN(day) || month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    const d: Date = new Date(year, month - 1, day);
    if (d.getFullYear() !== year || d.getMonth() !== month - 1 || d.getDate() !== day) {
      return null;
    }
    return d;
  }

  /** YYYY-MM-DD → 本地零点的 Date；格式不对返回 null */
  static parseYmd(s: string): Date | null {
    const m: RegExpMatchArray | null = s.trim().match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
    if (m === null) {
      return null;
    }
    return DateUtil.makeDate(parseInt(m[1]), parseInt(m[2]), parseInt(m[3]));
  }

  static isValidYmd(s: string): boolean {
    return DateUtil.parseYmd(s) !== null;
  }

  /** 把各种写法（2026/9/8、2026年9月8日）规整成 YYYY-MM-DD，失败返回空串 */
  static normalizeYmd(s: string): string {
    const m: RegExpMatchArray | null = s.trim().match(/^(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?$/);
    if (m === null) {
      return '';
    }
    const d: Date | null = DateUtil.makeDate(parseInt(m[1]), parseInt(m[2]), parseInt(m[3]));
    return d === null ? '' : DateUtil.formatDate(d);
  }

  /** HH:mm → 当天分钟数，格式不对返回 -1 */
  static parseHm(hhmm: string): number {
    const m: RegExpMatchArray | null = hhmm.trim().match(/^(\d{1,2}):(\d{2})$/);
    if (m === null) {
      return -1;
    }
    const h: number = parseInt(m[1]);
    const mi: number = parseInt(m[2]);
    if (h > 23 || mi > 59) {
      return -1;
    }
    return h * 60 + mi;
  }

  /** YYYY-MM-DD + HH:mm → 本地时间戳；任一格式不对返回 NaN */
  static toTimestamp(ymd: string, hhmm: string): number {
    const d: Date | null = DateUtil.parseYmd(ymd);
    const minutes: number = DateUtil.parseHm(hhmm);
    if (d === null || minutes < 0) {
      return NaN;
    }
    return new Date(d.getFullYear(), d.getMonth(), d.getDate(),
      Math.floor(minutes / 60), minutes % 60, 0).getTime();
  }

  static addDays(ymd: string, days: number): string {
    const d: Date | null = DateUtil.parseYmd(ymd);
    if (d === null) {
      return '';
    }
    return DateUtil.formatDate(new Date(d.getFullYear(), d.getMonth(), d.getDate() + days));
  }

  /** to - from 的自然日差；任一非法返回 NaN */
  static diffDays(fromYmd: string, toYmd: string): number {
    const a: Date | null = DateUtil.parseYmd(fromYmd);
    const b: Date | null = DateUtil.parseYmd(toYmd);
    if (a === null || b === null) {
      return NaN;
    }
    return Math.round((b.getTime() - a.getTime()) / DateUtil.DAY_MS);
  }

  static isPast(ymd: string, nowTs: number): boolean {
    const diff: number = DateUtil.diffDays(DateUtil.todayStr(nowTs), ymd);
    return !isNaN(diff) && diff < 0;
  }

  static weekdayLabel(d: Date): string {
    return WEEKDAY_LABEL[d.getDay()];
  }

  /** 给老人看的日期：今天 / 明天 / 后天 / 9月28日（周一） */
  static friendlyDate(ymd: string, nowTs: number): string {
    const d: Date | null = DateUtil.parseYmd(ymd);
    if (d === null) {
      return ymd.length > 0 ? ymd : '待定日期';
    }
    const diff: number = DateUtil.diffDays(DateUtil.todayStr(nowTs), ymd);
    if (diff === 0) {
      return '今天';
    }
    if (diff === 1) {
      return '明天';
    }
    if (diff === 2) {
      return '后天';
    }
    return `${d.getMonth() + 1}月${d.getDate()}日（${DateUtil.weekdayLabel(d)}）`;
  }

  static formatHm(ts: number): string {
    const d: Date = new Date(ts);
    return `${DateUtil.pad2(d.getHours())}:${DateUtil.pad2(d.getMinutes())}`;
  }

  /** 时间戳 → “今天 07:52 / 明天 07:52 / 9月28日 07:52” */
  static friendlyTime(ts: number, nowTs: number): string {
    const ymd: string = DateUtil.formatDate(new Date(ts));
    const diff: number = DateUtil.diffDays(DateUtil.todayStr(nowTs), ymd);
    let day: string = '';
    if (diff === 0) {
      day = '今天';
    } else if (diff === 1) {
      day = '明天';
    } else if (diff === -1) {
      day = '昨天';
    } else {
      const d: Date = new Date(ts);
      day = `${d.getMonth() + 1}月${d.getDate()}日`;
    }
    return `${day} ${DateUtil.formatHm(ts)}`;
  }

  /** HH:mm 减去若干分钟，结果不跨天（最早 00:00） */
  static minusMinutes(hhmm: string, minutes: number): string {
    const base: number = DateUtil.parseHm(hhmm);
    if (base < 0) {
      return hhmm;
    }
    const total: number = Math.max(0, base - minutes);
    return `${DateUtil.pad2(Math.floor(total / 60))}:${DateUtil.pad2(total % 60)}`;
  }

  /** 支持 1~31 的阿拉伯数字与中文数字（一、十二、二十五、两） */
  static parseChineseNumber(s: string): number {
    const t: string = s.trim();
    if (/^\d+$/.test(t)) {
      return parseInt(t);
    }
    if (t === '十') {
      return 10;
    }
    const tenIdx: number = t.indexOf('十');
    if (tenIdx >= 0) {
      const before: string = t.substring(0, tenIdx);
      const after: string = t.substring(tenIdx + 1);
      const tensValue: number | undefined = before.length === 0 ? 1 : CN_DIGITS[before];
      const onesValue: number | undefined = after.length === 0 ? 0 : CN_DIGITS[after];
      if (tensValue === undefined || onesValue === undefined) {
        return -1;
      }
      return tensValue * 10 + onesValue;
    }
    if (t.length === 1) {
      const v: number | undefined = CN_DIGITS[t];
      return v === undefined ? -1 : v;
    }
    return -1;
  }

  /**
   * 口语日期 → YYYY-MM-DD。优先级：绝对日期 > 今明后天 > 星期 > N天后 > X号。
   * 周的约定与中文习惯一致：一周从周一开始，“下周三”指下一个自然周的周三。
   */
  static parseChineseDate(text: string, nowTs: number): DateHint {
    const t: string = text.replace(/\s+/g, '');
    const now: Date = new Date(nowTs);
    const todayStart: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());

    // 1. 绝对日期：2026-09-28 / 2026年9月28日
    const abs: RegExpMatchArray | null = t.match(/(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})[日号]?/);
    if (abs !== null) {
      const d: Date | null = DateUtil.makeDate(parseInt(abs[1]), parseInt(abs[2]), parseInt(abs[3]));
      if (d !== null) {
        return DateUtil.hint(DateUtil.formatDate(d), '');
      }
    }

    // 2. 下个月X号
    const nextMonth: RegExpMatchArray | null = t.match(/下个?月([0-9一二两三四五六七八九十]{1,3})[日号]/);
    if (nextMonth !== null) {
      const day: number = DateUtil.parseChineseNumber(nextMonth[1]);
      const d: Date | null = DateUtil.makeDate(
        now.getMonth() === 11 ? now.getFullYear() + 1 : now.getFullYear(),
        now.getMonth() === 11 ? 1 : now.getMonth() + 2, day);
      if (d !== null) {
        return DateUtil.hint(DateUtil.formatDate(d), '');
      }
    }

    // 3. X月X日 / X月X号（已过则顺延到明年）
    const md: RegExpMatchArray | null = t.match(/([0-9一二两三四五六七八九十]{1,3})月([0-9一二两三四五六七八九十]{1,3})[日号]?/);
    if (md !== null) {
      const month: number = DateUtil.parseChineseNumber(md[1]);
      const day: number = DateUtil.parseChineseNumber(md[2]);
      let d: Date | null = DateUtil.makeDate(now.getFullYear(), month, day);
      if (d !== null && d.getTime() < todayStart.getTime()) {
        d = DateUtil.makeDate(now.getFullYear() + 1, month, day);
      }
      if (d !== null) {
        return DateUtil.hint(DateUtil.formatDate(d), '');
      }
    }

    // 4. 今天 / 明天 / 后天 / 大后天
    if (t.indexOf('大后天') >= 0) {
      return DateUtil.hint(DateUtil.dateAfter(nowTs, 3), '');
    }
    if (t.indexOf('后天') >= 0) {
      return DateUtil.hint(DateUtil.dateAfter(nowTs, 2), '');
    }
    if (/(明天|明日|明早|明儿|明个)/.test(t)) {
      return DateUtil.hint(DateUtil.dateAfter(nowTs, 1), '');
    }
    if (/(今天|今日|今早|今儿|今个|今天下午)/.test(t)) {
      return DateUtil.hint(DateUtil.dateAfter(nowTs, 0), '');
    }

    // 5. 星期：周三 / 这周五 / 下周三 / 下下周一 / 下个星期二
    const wk: RegExpMatchArray | null = t.match(/(下下|下个|下|这个|这|本)?(周|星期|礼拜)([一二三四五六日天1-7])/);
    if (wk !== null) {
      const target: number | undefined = WEEKDAY_NUM[wk[3]];
      if (target !== undefined) {
        const prefix: string = wk[1] === undefined ? '' : wk[1];
        const current: number = now.getDay() === 0 ? 7 : now.getDay();
        let delta: number = 0;
        if (prefix === '下下') {
          delta = (7 - current) + target + 7;
        } else if (prefix === '下' || prefix === '下个') {
          delta = (7 - current) + target;
        } else if (prefix === '这' || prefix === '这个' || prefix === '本') {
          delta = target - current;
        } else {
          delta = target - current;
          if (delta <= 0) {
            delta += 7;
          }
        }
        return DateUtil.hint(DateUtil.dateAfter(nowTs, delta), '');
      }
    }

    // 6. N天后 / 过N天
    const after: RegExpMatchArray | null = t.match(/([0-9一二两三四五六七八九十]{1,3})天(后|以后|之后)/);
    if (after !== null) {
      const n: number = DateUtil.parseChineseNumber(after[1]);
      if (n >= 0 && n <= 90) {
        return DateUtil.hint(DateUtil.dateAfter(nowTs, n), '');
      }
    }
    const pass: RegExpMatchArray | null = t.match(/过([0-9一二两三四五六七八九十]{1,3})天/);
    if (pass !== null) {
      const n: number = DateUtil.parseChineseNumber(pass[1]);
      if (n >= 0 && n <= 90) {
        return DateUtil.hint(DateUtil.dateAfter(nowTs, n), '');
      }
    }

    // 7. 单独的 X号（本月已过则顺延到下个月）
    const dayOnly: RegExpMatchArray | null = t.match(/([0-9一二两三四五六七八九十]{1,3})[号日]/);
    if (dayOnly !== null) {
      const day: number = DateUtil.parseChineseNumber(dayOnly[1]);
      let d: Date | null = DateUtil.makeDate(now.getFullYear(), now.getMonth() + 1, day);
      if (d !== null && d.getTime() < todayStart.getTime()) {
        const nextYear: number = now.getMonth() === 11 ? now.getFullYear() + 1 : now.getFullYear();
        const nextMonthNum: number = now.getMonth() === 11 ? 1 : now.getMonth() + 2;
        d = DateUtil.makeDate(nextYear, nextMonthNum, day);
      }
      if (d !== null) {
        return DateUtil.hint(DateUtil.formatDate(d), '');
      }
    }

    // 8. 只有范围、没有具体哪天
    if (/下个?(周|星期|礼拜)/.test(t)) {
      return DateUtil.hint('', '下周');
    }
    if (/(这|本)(周|星期|礼拜)|周末/.test(t)) {
      return DateUtil.hint('', '这周');
    }
    if (/(过几天|过两天|改天|最近几天|这几天)/.test(t)) {
      return DateUtil.hint('', '过几天');
    }

    // 9. 昨天 / 前天：返回过去的日期，由调用方提示“已经过去了”
    if (t.indexOf('前天') >= 0 && t.indexOf('大前天') < 0) {
      return DateUtil.hint(DateUtil.dateAfter(nowTs, -2), '');
    }
    if (/(昨天|昨日|昨儿)/.test(t)) {
      return DateUtil.hint(DateUtil.dateAfter(nowTs, -1), '');
    }
    return DateUtil.hint('', '');
  }

  /** 上午 / 下午 偏好 */
  static parseTimePreference(text: string): string {
    if (/(上午|早上|早晨|一早|早点|清早|明早|今早)/.test(text)) {
      return '上午';
    }
    if (/(下午|午后|傍晚|晚上)/.test(text)) {
      return '下午';
    }
    return '';
  }

  private static hint(date: string, vague: string): DateHint {
    const h: DateHint = { date: date, vague: vague };
    return h;
  }
}
