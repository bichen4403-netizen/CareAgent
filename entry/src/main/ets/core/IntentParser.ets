/**
 * 智护同行 - 意图理解
 *
 * 把老人一句自然语言（"我要去第一人民医院拿高血压药"）
 * 转成结构化的 ParsedIntent，并结合端侧历史记录补全缺失槽位。
 * 这是"从单点指令到连续任务"的第一步。
 */

import { ParsedIntent, IntentType, RuntimeContext, ServiceRecord } from './AgentTypes';
import { ContextStore } from './ContextStore';
import { LLMService, LLMMessage } from '../services/LLMService';

const SYSTEM_PROMPT: string = `你是就医陪诊助手的意图理解模块，服务对象是老年人。
请把用户的一句话需求解析为 JSON，不要输出任何解释文字或 markdown 代码块标记。
字段说明：
type: MEDICAL_VISIT(就诊/复查) | MEDICINE_REFILL(取药/续方) | REPORT_QUERY(查报告) | UNKNOWN
hospital: 医院名称，未提及则空字符串
department: 科室，可根据病症推断（如高血压→心血管内科），无法推断则空字符串
purpose: 用户原话
expectedDate: YYYY-MM-DD，用户说"明天""下周"等需按当前日期换算，未提及则空字符串
isRevisit: 是否复诊，true/false
confidence: 0到1的置信度
missingSlots: 缺失且必须向用户确认的字段名数组
只输出 JSON 对象。`;

export class IntentParser {

  /**
   * 解析用户输入
   * @param userText 用户语音转写文本
   * @param rt 当前运行时上下文（位置/天气/时间）
   */
  static async parse(userText: string, rt: RuntimeContext): Promise<ParsedIntent> {
    const store: ContextStore = ContextStore.getInstance();
    const ctxSummary: string = store.buildContextSummary(rt);
    const today: string = IntentParser.formatDate(new Date(rt.nowTs));

    const messages: LLMMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: `今天是${today}。用户背景：${ctxSummary}。\n用户说："${userText}"` }
    ];

    const raw: string = await LLMService.chat(messages);
    let intent: ParsedIntent = IntentParser.safeParse(raw, userText);
    intent = IntentParser.enrichFromHistory(intent, store);
    intent = IntentParser.ensureRequiredSlots(intent);
    return intent;
  }

  /** 日期是生成出行和提醒时间的必要条件，不能用“明天”等默认值代替。 */
  private static ensureRequiredSlots(intent: ParsedIntent): ParsedIntent {
    if ((intent.type === IntentType.MEDICAL_VISIT || intent.type === IntentType.MEDICINE_REFILL) &&
        intent.expectedDate.length === 0 && !IntentParser.hasSlot(intent.missingSlots, 'expectedDate')) {
      intent.missingSlots.push('expectedDate');
    }
    return intent;
  }

  private static hasSlot(slots: string[], name: string): boolean {
    for (let i = 0; i < slots.length; i++) {
      if (slots[i] === name) {
        return true;
      }
    }
    return false;
  }

  /** 容错解析：模型可能带 markdown 包裹或多余文字 */
  private static safeParse(raw: string, fallbackText: string): ParsedIntent {
    let jsonStr: string = raw.trim();
    const start: number = jsonStr.indexOf('{');
    const end: number = jsonStr.lastIndexOf('}');
    if (start >= 0 && end > start) {
      jsonStr = jsonStr.substring(start, end + 1);
    }

    try {
      const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
      const typeStr: string = typeof obj['type'] === 'string' ? obj['type'] as string : 'UNKNOWN';
      const hospital: string = typeof obj['hospital'] === 'string' ? obj['hospital'] as string : '';
      const department: string = typeof obj['department'] === 'string'
        ? obj['department'] as string : '';
      const purpose: string = typeof obj['purpose'] === 'string'
        ? obj['purpose'] as string : fallbackText;
      const expectedDate: string = typeof obj['expectedDate'] === 'string'
        ? obj['expectedDate'] as string : '';
      const isRevisit: boolean = typeof obj['isRevisit'] === 'boolean'
        ? obj['isRevisit'] as boolean : false;
      const confidence: number = typeof obj['confidence'] === 'number'
        ? Math.max(0, Math.min(1, obj['confidence'] as number)) : 0.5;
      const slots: string[] = [];
      const rawSlots: Object | undefined = obj['missingSlots'];
      if (Array.isArray(rawSlots)) {
        const slotValues: Object[] = rawSlots as Object[];
        for (let i = 0; i < slotValues.length; i++) {
          if (typeof slotValues[i] === 'string') {
            slots.push(slotValues[i] as string);
          }
        }
      }
      return {
        type: IntentParser.toIntentType(typeStr),
        hospital: hospital.trim(),
        department: department.trim(),
        purpose: purpose.trim(),
        expectedDate: expectedDate.trim(),
        isRevisit: isRevisit,
        confidence: confidence,
        missingSlots: slots
      };
    } catch (e) {
      console.error(`[IntentParser] parse failed: ${e}`);
      return {
        type: IntentType.UNKNOWN,
        hospital: '',
        department: '',
        purpose: fallbackText,
        expectedDate: '',
        isRevisit: false,
        confidence: 0,
        missingSlots: ['hospital', 'department']
      };
    }
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

  /**
   * 用历史服务记录补全槽位 —— 体验上最"懂你"的一步：
   * 老人只说"我要拿高血压药"，系统自动补出上次的医院、科室、医生
   */
  private static enrichFromHistory(intent: ParsedIntent, store: ContextStore): ParsedIntent {
    if (intent.hospital.length > 0 && intent.department.length > 0) {
      return intent;
    }

    // 历史科室只用于复诊/续方等明确的延续性请求。
    // 新的检查或首次就诊不能套用上次科室（例如上次心内科、这次做胃镜）。
    const allowHistory: boolean = intent.isRevisit ||
      intent.type === IntentType.MEDICINE_REFILL ||
      intent.purpose.indexOf('复查') >= 0 || intent.purpose.indexOf('复诊') >= 0 ||
      intent.purpose.indexOf('拿药') >= 0 || intent.purpose.indexOf('取药') >= 0 ||
      intent.purpose.indexOf('续方') >= 0;
    const last: ServiceRecord | null = allowHistory
      ? store.findLastVisit(intent.hospital, intent.department) : null;
    if (last === null) {
      const preferred: string[] = store.getProfile().preferredHospitals;
      if (intent.hospital.length === 0 && preferred.length > 0) {
        intent.hospital = preferred[0];
        intent.missingSlots = IntentParser.removeSlot(intent.missingSlots, 'hospital');
      }
      return intent;
    }

    if (intent.hospital.length === 0) {
      intent.hospital = last.hospital;
      intent.missingSlots = IntentParser.removeSlot(intent.missingSlots, 'hospital');
    }
    if (intent.department.length === 0) {
      intent.department = last.department;
      intent.missingSlots = IntentParser.removeSlot(intent.missingSlots, 'department');
    }
    if (last.followUpDays > 0) {
      intent.isRevisit = true;
    }
    return intent;
  }

  private static removeSlot(slots: string[], name: string): string[] {
    const out: string[] = [];
    for (let i = 0; i < slots.length; i++) {
      if (slots[i] !== name) {
        out.push(slots[i]);
      }
    }
    return out;
  }

  /** 生成澄清问题 —— 老年用户友好原则：一次只问一个，且可直接语音回答 */
  static buildClarifyQuestion(intent: ParsedIntent): string {
    if (intent.missingSlots.length === 0) {
      return '';
    }
    const slot: string = intent.missingSlots[0];
    if (slot === 'hospital') {
      return '您想去哪家医院？';
    }
    if (slot === 'department') {
      return '您这次是看什么科呢？';
    }
    if (slot === 'expectedDate') {
      return '您想哪天去？';
    }
    return '还需要您补充一下信息';
  }

  static formatDate(d: Date): string {
    const m: string = `${d.getMonth() + 1}`.padStart(2, '0');
    const day: string = `${d.getDate()}`.padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }
}
