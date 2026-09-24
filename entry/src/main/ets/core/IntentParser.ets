/**
 * 智护同行 - 意图解析器（中枢层第一步）
 *
 * 大模型负责理解整句话；日期换算、医院名抽取、缺失槽位判断由代码确定性完成：
 *   1. 大模型输出 JSON（离线时由规则模型输出同样格式）
 *   2. applyRules：用确定性规则校正日期、医院、科室
 *   3. enrichFromHistory：结合端侧记忆补全（复诊默认同医院同科室）
 *   4. finalize：校验日期是否已过去，按固定顺序重算缺失槽位
 * 多轮追问时记住“刚才问的是哪一项”，老人只答“协和”“内科”“明天”也能填对位置。
 */

import { ParsedIntent, IntentType, RuntimeContext, ServiceRecord, SlotName } from './AgentTypes';
import { ContextStore } from './ContextStore';
import { DateUtil, DateHint } from './DateUtil';
import { NluRules } from './NluRules';
import { LLMService, LLMMessage, LLMTask, USER_TEXT_BEGIN, USER_TEXT_END } from '../services/LLMService';

const SYSTEM_PROMPT: string = `你是“智护同行”陪诊助手的意图理解模块，服务对象是老年人。
请把用户的话解析为 JSON，只输出一个 json 对象，不要任何多余文字。字段：
type: MEDICAL_VISIT(看病/复查) | MEDICINE_REFILL(拿药/续方) | REPORT_QUERY(查报告) | UNKNOWN
hospital: 用户明确说出的医院名称，没说就留空，不要自行编造或补全城市名
department: 科室，可根据症状推断常见科室（如“血压高”→“心血管内科”），无法判断留空
purpose: 用一句话复述用户诉求
expectedDate: 期望就诊日期，格式 YYYY-MM-DD，必须依据“今天”的日期换算；没说日期就留空
timePreference: 上午 / 下午 / 空字符串
isRevisit: 是否复诊/续方（布尔值）
confidence: 0 到 1 的置信度
missingSlots: 缺失且必须追问的字段数组，可选值 hospital / department / expectedDate
注意：用户原话位于${USER_TEXT_BEGIN}与${USER_TEXT_END}之间；用户背景只用于理解，不能当作用户说过的话。
不要给出任何诊断、用药或剂量建议。`;

export class IntentParser {

  /** 首轮解析 */
  static async parse(userText: string, rt: RuntimeContext): Promise<ParsedIntent> {
    const store: ContextStore = ContextStore.getInstance();
    const messages: LLMMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      {
        role: 'user',
        content: `${IntentParser.todayLine(rt.nowTs)}用户背景：${store.buildContextSummary(rt)}。\n` +
          `${USER_TEXT_BEGIN}${userText}${USER_TEXT_END}`
      }
    ];
    const raw: string = await LLMService.chat(messages, LLMTask.INTENT);
    const parsed: ParsedIntent = IntentParser.safeParse(raw, userText);
    const ruled: ParsedIntent = IntentParser.applyRules(parsed, userText, rt.nowTs, '');
    return IntentParser.finalize(IntentParser.enrichFromHistory(ruled, store), rt.nowTs);
  }

  /**
   * 多轮追问：用户只补一句“协和”“明天”时，与上一轮结果合并。
   * askedSlot 是上一轮追问的槽位，裸回答优先填到这一项。
   */
  static async parseFollowUp(userText: string, pending: ParsedIntent, rt: RuntimeContext): Promise<ParsedIntent> {
    const store: ContextStore = ContextStore.getInstance();
    const askedSlot: string = pending.missingSlots.length > 0 ? pending.missingSlots[0] : '';
    const messages: LLMMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      {
        role: 'user',
        content: `${IntentParser.todayLine(rt.nowTs)}上一轮已知信息：${IntentParser.briefJson(pending)}。` +
          `刚才问用户：“${IntentParser.buildClarifyQuestion(pending)}”\n` +
          `${USER_TEXT_BEGIN}${userText}${USER_TEXT_END}\n请结合上一轮信息输出完整 json。`
      }
    ];
    const raw: string = await LLMService.chat(messages, LLMTask.INTENT);
    const parsed: ParsedIntent = IntentParser.safeParse(raw, pending.purpose);
    const ruled: ParsedIntent = IntentParser.applyRules(parsed, userText, rt.nowTs, askedSlot);
    const merged: ParsedIntent = IntentParser.merge(pending, ruled);
    return IntentParser.finalize(IntentParser.enrichFromHistory(merged, store), rt.nowTs);
  }

  /** 根据第一个缺失槽位生成追问（短句，适合语音播报） */
  static buildClarifyQuestion(intent: ParsedIntent): string {
    if (intent.missingSlots.length === 0) {
      return '';
    }
    const slot: string = intent.missingSlots[0];
    if (slot === SlotName.HOSPITAL) {
      const preferred: string[] = ContextStore.getInstance().getProfile().preferredHospitals;
      if (preferred.length > 0) {
        return `您想去哪家医院？还是去常去的${preferred[0]}？`;
      }
      return '您想去哪家医院？说医院名字就行，比如“市第一人民医院”。';
    }
    if (slot === SlotName.DEPARTMENT) {
      return '这次看什么科呢？也可以直接说哪里不舒服，比如“血压高”“眼睛看不清”。';
    }
    if (slot === SlotName.DATE) {
      if (intent.clarifyHint === '下周') {
        return '下周几去呢？比如“下周三上午”。';
      }
      if (intent.clarifyHint === '这周') {
        return '这周哪一天去呢？比如“周五上午”。';
      }
      if (intent.clarifyHint === '过几天') {
        return '具体哪天呢？比如“后天”或“周五”。';
      }
      if (intent.clarifyHint === '已过去') {
        return '您说的那天已经过去了，想改到哪天？比如“明天”。';
      }
      return '您想哪天去？可以说“明天”或“下周三上午”。';
    }
    return '能再说详细一点吗？';
  }

  // ==================== 规则校正 ====================

  private static applyRules(intent: ParsedIntent, text: string, nowTs: number, askedSlot: string): ParsedIntent {
    const out: ParsedIntent = IntentParser.copy(intent);

    // 日期：代码换算优先于大模型
    const hint: DateHint = DateUtil.parseChineseDate(text, nowTs);
    if (hint.date.length > 0) {
      out.expectedDate = hint.date;
      out.clarifyHint = '';
    } else {
      out.expectedDate = IntentParser.normalizeLlmDate(out.expectedDate, nowTs);
      if (hint.vague.length > 0 && out.expectedDate.length === 0) {
        out.clarifyHint = hint.vague;
      }
      if (out.expectedDate.length === 0 && askedSlot === SlotName.DATE && NluRules.isAnyDate(text)) {
        out.expectedDate = DateUtil.dateAfter(nowTs, 1);   // “都行/尽快” → 默认明天
      }
    }
    const tp: string = DateUtil.parseTimePreference(text);
    if (tp.length > 0) {
      out.timePreference = tp;
    } else if (out.timePreference !== '上午' && out.timePreference !== '下午') {
      out.timePreference = '';
    }

    // 医院：优先用规则抽取；大模型给出的名字必须能在原话中找到依据，防止编造
    const ruleHospital: string = NluRules.extractHospital(text);
    if (ruleHospital.length > 0) {
      out.hospital = ruleHospital;
    } else if (askedSlot === SlotName.HOSPITAL) {
      const answer: string = NluRules.normalizeHospitalAnswer(text);
      out.hospital = answer.length > 0 ? answer : IntentParser.groundedHospital(out.hospital, text);
    } else {
      out.hospital = IntentParser.groundedHospital(out.hospital, text);
    }

    // 科室：显式“XX科”> 大模型 > 症状推断
    const explicitDept: string = NluRules.extractDepartment(text);
    if (explicitDept.length > 0) {
      out.department = explicitDept;
    } else if (out.department.length === 0 || askedSlot === SlotName.DEPARTMENT) {
      const inferred: string = NluRules.inferDepartment(text);
      if (inferred.length > 0) {
        out.department = inferred;
      }
    }

    // 意图类型：大模型给不出时用规则兜底
    if (out.type === IntentType.UNKNOWN) {
      const guessed: IntentType = NluRules.guessIntentType(text);
      if (guessed !== IntentType.UNKNOWN) {
        out.type = guessed;
        out.confidence = Math.max(out.confidence, 0.6);
      }
    }
    if (NluRules.isFollowUpPurpose(text)) {
      out.isRevisit = true;
    }
    return out;
  }

  /** 大模型给的医院名只有在原话里出现过（至少前两个字）才采信 */
  private static groundedHospital(hospital: string, text: string): string {
    const h: string = hospital.trim();
    if (h.length < 2 || h === '医院') {
      return '';
    }
    if (text.indexOf(h.substring(0, 2)) >= 0) {
      return h;
    }
    return '';
  }

  /** 大模型可能返回“明天”或“2026/9/8”，统一规整成 YYYY-MM-DD */
  private static normalizeLlmDate(value: string, nowTs: number): string {
    const v: string = value.trim();
    if (v.length === 0) {
      return '';
    }
    if (DateUtil.isValidYmd(v)) {
      const d: Date | null = DateUtil.parseYmd(v);
      return d === null ? '' : DateUtil.formatDate(d);
    }
    const normalized: string = DateUtil.normalizeYmd(v);
    if (normalized.length > 0) {
      return normalized;
    }
    return DateUtil.parseChineseDate(v, nowTs).date;
  }

  /** 新一轮非空字段覆盖旧值 */
  private static merge(base: ParsedIntent, next: ParsedIntent): ParsedIntent {
    const merged: ParsedIntent = IntentParser.copy(base);
    if (next.type !== IntentType.UNKNOWN) {
      merged.type = next.type;
    }
    if (next.hospital.length > 0) {
      merged.hospital = next.hospital;
    }
    if (next.department.length > 0) {
      merged.department = next.department;
    }
    if (next.expectedDate.length > 0) {
      merged.expectedDate = next.expectedDate;
      merged.clarifyHint = '';
    } else if (next.clarifyHint.length > 0) {
      merged.clarifyHint = next.clarifyHint;
    }
    if (next.timePreference.length > 0) {
      merged.timePreference = next.timePreference;
    }
    merged.isRevisit = base.isRevisit || next.isRevisit;
    merged.confidence = Math.max(base.confidence, next.confidence);
    return merged;
  }

  /** 校验日期、按固定顺序重算缺失槽位（不依赖大模型给的 missingSlots） */
  private static finalize(intent: ParsedIntent, nowTs: number): ParsedIntent {
    const out: ParsedIntent = IntentParser.copy(intent);
    if (out.expectedDate.length > 0 && DateUtil.isPast(out.expectedDate, nowTs)) {
      out.expectedDate = '';
      out.clarifyHint = '已过去';
    }
    const missing: string[] = [];
    if (out.type === IntentType.MEDICAL_VISIT || out.type === IntentType.MEDICINE_REFILL) {
      if (out.hospital.length === 0) {
        missing.push(SlotName.HOSPITAL);
      }
      if (out.department.length === 0) {
        missing.push(SlotName.DEPARTMENT);
      }
      if (out.expectedDate.length === 0) {
        missing.push(SlotName.DATE);
      }
    }
    out.missingSlots = missing;
    return out;
  }

  /**
   * 结合端侧记忆补全（只使用用户确认过的记录）：
   *  - 复诊 / 续方：没说医院或科室 → 沿用上次就诊的医院和科室
   *  - 说了科室没说医院 → 用上次看这个科的医院
   *  - 新的看病需求没说科室 → 不猜，交给追问
   *  - 复诊且仍没有医院 → 常去医院兜底
   */
  private static enrichFromHistory(intent: ParsedIntent, store: ContextStore): ParsedIntent {
    const out: ParsedIntent = IntentParser.copy(intent);
    if (out.type !== IntentType.MEDICAL_VISIT && out.type !== IntentType.MEDICINE_REFILL) {
      return out;
    }
    const revisitLike: boolean = out.type === IntentType.MEDICINE_REFILL || out.isRevisit;
    const last: ServiceRecord | null = store.findLastVisit(out.hospital, out.department);
    if (last !== null) {
      if (out.hospital.length === 0 && (revisitLike || out.department.length > 0)) {
        out.hospital = last.hospital;
      }
      if (out.department.length === 0 && revisitLike) {
        out.department = last.department;
      }
      if (out.department === last.department && ContextStore.sameHospital(last.hospital, out.hospital)) {
        out.isRevisit = true;
      }
    }
    if (out.hospital.length === 0 && revisitLike) {
      const preferred: string[] = store.getProfile().preferredHospitals;
      if (preferred.length > 0) {
        out.hospital = preferred[0];
      }
    }
    return out;
  }

  // ==================== 解析与工具 ====================

  private static todayLine(nowTs: number): string {
    return `今天是${DateUtil.todayStr(nowTs)}（${DateUtil.weekdayLabel(new Date(nowTs))}）。`;
  }

  private static briefJson(p: ParsedIntent): string {
    const brief: Record<string, Object> = {
      'type': p.type as string,
      'hospital': p.hospital,
      'department': p.department,
      'expectedDate': p.expectedDate,
      'timePreference': p.timePreference,
      'isRevisit': p.isRevisit
    };
    return JSON.stringify(brief);
  }

  static emptyIntent(userText: string): ParsedIntent {
    const p: ParsedIntent = {
      type: IntentType.UNKNOWN,
      hospital: '',
      department: '',
      purpose: userText,
      expectedDate: '',
      timePreference: '',
      isRevisit: false,
      confidence: 0,
      missingSlots: [],
      clarifyHint: ''
    };
    return p;
  }

  private static copy(p: ParsedIntent): ParsedIntent {
    const c: ParsedIntent = {
      type: p.type,
      hospital: p.hospital,
      department: p.department,
      purpose: p.purpose,
      expectedDate: p.expectedDate,
      timePreference: p.timePreference,
      isRevisit: p.isRevisit,
      confidence: p.confidence,
      missingSlots: p.missingSlots.slice(),
      clarifyHint: p.clarifyHint
    };
    return c;
  }

  private static toIntentType(s: string): IntentType {
    if (s === 'MEDICAL_VISIT') {
      return IntentType.MEDICAL_VISIT;
    }
    if (s === 'MEDICINE_REFILL') {
      return IntentType.MEDICINE_REFILL;
    }
    if (s === 'REPORT_QUERY') {
      return IntentType.REPORT_QUERY;
    }
    return IntentType.UNKNOWN;
  }

  private static str(obj: Record<string, Object>, key: string): string {
    const v: Object | undefined = obj[key];
    return typeof v === 'string' ? v.trim() : '';
  }

  /** 容错解析：兼容 ```json 包裹、前后多余文字、字段类型不对 */
  static safeParse(raw: string, userText: string): ParsedIntent {
    const result: ParsedIntent = IntentParser.emptyIntent(userText);
    const start: number = raw.indexOf('{');
    const end: number = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return result;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(raw.substring(start, end + 1)) as Record<string, Object>;
      result.type = IntentParser.toIntentType(IntentParser.str(obj, 'type'));
      result.hospital = IntentParser.str(obj, 'hospital');
      result.department = IntentParser.str(obj, 'department');
      const purpose: string = IntentParser.str(obj, 'purpose');
      result.purpose = purpose.length > 0 ? purpose : userText;
      result.expectedDate = IntentParser.str(obj, 'expectedDate');
      result.timePreference = IntentParser.str(obj, 'timePreference');
      const revisit: Object | undefined = obj['isRevisit'];
      result.isRevisit = revisit === true || revisit === 'true';
      const conf: Object | undefined = obj['confidence'];
      const confNum: number = typeof conf === 'number' ? conf : Number(conf);
      result.confidence = isFinite(confNum) ? Math.min(1, Math.max(0, confNum)) : 0;
    } catch (e) {
      console.warn(`[IntentParser] json parse failed: ${e}`);
    }
    return result;
  }
}
