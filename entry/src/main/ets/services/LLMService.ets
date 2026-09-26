/**
 * 智护同行 - 大模型能力封装（平台适配层）
 *
 * 把“调模型”收敛成 LLMProvider 接口，后续切换其他自建或第三方模型时只需新增一个实现：
 *   - HttpLLMProvider ：经 backend/ 网关调用 DeepSeek 等 OpenAI 兼容模型
 *   - MockLLMProvider ：离线规则模型，无网络也能完整演示（意图理解 + 处方单字段抽取）
 *
 * 任何网络异常都会自动退回离线规则，页面上会标注“离线规则理解”，不冒充大模型结果。
 */

import { http } from '@kit.NetworkKit';
import { BackendConfig } from '../config/BackendConfig';
import { NluRules } from '../core/NluRules';
import { DateUtil, DateHint } from '../core/DateUtil';
import { IntentType } from '../core/AgentTypes';

/** 调用目的：离线规则模型据此选择对应的规则 */
export enum LLMTask {
  INTENT = 'INTENT',
  RECORD_EXTRACT = 'RECORD_EXTRACT'
}

export interface LLMMessage {
  role: string;      // system / user / assistant
  content: string;
}

export interface LLMProvider {
  readonly name: string;
  chat(messages: LLMMessage[], task: LLMTask): Promise<string>;
}

/** 用户原话在提示词中的包裹标记：离线规则只解析这一段，避免把“常去医院”等背景当成本次需求 */
export const USER_TEXT_BEGIN: string = '【用户原话】';
export const USER_TEXT_END: string = '【原话结束】';

// ==================== HTTP 实现 ====================

export class HttpLLMProvider implements LLMProvider {
  readonly name: string;
  private endpoint: string;
  private token: string;
  private model: string;
  private viaGateway: boolean;

  /**
   * @param viaGateway true 表示请求自建网关（由网关注入密钥与 JSON 模式）；
   *                   false 表示直连 OpenAI 兼容接口（仅用于本地调试，不要把密钥写进客户端）
   */
  constructor(endpoint: string, token: string, model: string, viaGateway: boolean, name: string) {
    this.endpoint = endpoint;
    this.token = token;
    this.model = model;
    this.viaGateway = viaGateway;
    this.name = name;
  }

  async chat(messages: LLMMessage[], task: LLMTask): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const bodyObj: Record<string, Object> = {
        'messages': messages,
        'temperature': 0.1,
        'stream': false
      };
      if (this.model.length > 0) {
        bodyObj['model'] = this.model;
      }
      if (this.viaGateway) {
        bodyObj['json_mode'] = true;
      } else {
        const format: Record<string, Object> = { 'type': 'json_object' };
        bodyObj['response_format'] = format;
      }
      const headers: Record<string, string> = this.viaGateway
        ? BackendConfig.headers() : { 'Content-Type': 'application/json' };
      if (this.token.length > 0) {
        headers['Authorization'] = `Bearer ${this.token}`;
      }
      const resp: http.HttpResponse = await req.request(this.endpoint, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(bodyObj),
        connectTimeout: 5000,
        readTimeout: 15000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`LLM HTTP ${resp.responseCode}`);
      }
      return HttpLLMProvider.extractContent(resp.result as string);
    } finally {
      req.destroy();
    }
  }

  /** 兼容 OpenAI 风格返回结构，解析失败则原样返回 */
  private static extractContent(raw: string): string {
    try {
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const choices: Object | undefined = obj['choices'];
      if (Array.isArray(choices)) {
        const list: Object[] = choices as Object[];
        if (list.length > 0) {
          const first: Record<string, Object> = list[0] as Record<string, Object>;
          const msg: Object | undefined = first['message'];
          if (msg !== undefined && msg !== null && typeof msg === 'object') {
            const content: Object | undefined = (msg as Record<string, Object>)['content'];
            if (typeof content === 'string') {
              return content;
            }
          }
        }
      }
    } catch (e) {
      console.warn(`[LLM] parse fallback: ${e}`);
    }
    return raw;
  }
}

// ==================== 离线规则实现（答辩兜底） ====================

export class MockLLMProvider implements LLMProvider {
  readonly name: string = 'offline-rules';

  async chat(messages: LLMMessage[], task: LLMTask): Promise<string> {
    let userText: string = '';
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === 'user') {
        userText = messages[i].content;
        break;
      }
    }
    await MockLLMProvider.delay(250);
    if (task === LLMTask.RECORD_EXTRACT) {
      return NluRules.extractRecordJson(userText);
    }
    return MockLLMProvider.ruleBasedIntent(MockLLMProvider.extractRequestText(userText));
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 从 IntentParser 的包装消息中提取用户原话 */
  static extractRequestText(text: string): string {
    const start: number = text.lastIndexOf(USER_TEXT_BEGIN);
    if (start >= 0) {
      const contentStart: number = start + USER_TEXT_BEGIN.length;
      const end: number = text.indexOf(USER_TEXT_END, contentStart);
      if (end > contentStart) {
        return text.substring(contentStart, end);
      }
      return text.substring(contentStart);
    }
    return text;
  }

  private static ruleBasedIntent(text: string): string {
    const type: IntentType = NluRules.guessIntentType(text);
    const hospital: string = NluRules.extractHospital(text);
    const department: string = NluRules.resolveDepartment(text);
    const hint: DateHint = DateUtil.parseChineseDate(text, Date.now());
    const missing: string[] = [];
    if (hospital.length === 0) {
      missing.push('hospital');
    }
    if (department.length === 0) {
      missing.push('department');
    }
    if ((type === IntentType.MEDICAL_VISIT || type === IntentType.MEDICINE_REFILL) && hint.date.length === 0) {
      missing.push('expectedDate');
    }
    const result: Record<string, Object> = {
      'type': type as string,
      'hospital': hospital,
      'department': department,
      'purpose': text,
      'expectedDate': hint.date,
      'timePreference': DateUtil.parseTimePreference(text),
      'isRevisit': NluRules.isFollowUpPurpose(text),
      'confidence': type === IntentType.UNKNOWN ? 0.3 : 0.85,
      'missingSlots': missing
    };
    return JSON.stringify(result);
  }
}

// ==================== 单例管理 ====================

export class LLMService {
  private static provider: LLMProvider = new MockLLMProvider();
  private static lastProvider: string = 'offline-rules';

  /** App 启动时按配置注入真实 Provider */
  static setProvider(p: LLMProvider): void {
    LLMService.provider = p;
  }

  static isRemote(): boolean {
    return LLMService.provider.name !== 'offline-rules';
  }

  /** 最近一次实际给出结果的是谁：大模型网关还是离线规则 */
  static lastProviderName(): string {
    return LLMService.lastProvider;
  }

  static async chat(messages: LLMMessage[], task: LLMTask = LLMTask.INTENT): Promise<string> {
    try {
      const result: string = await LLMService.provider.chat(messages, task);
      LLMService.lastProvider = LLMService.provider.name;
      return result;
    } catch (e) {
      console.error(`[LLMService] ${LLMService.provider.name} failed, fallback to offline rules: ${e}`);
      const fallback: MockLLMProvider = new MockLLMProvider();
      LLMService.lastProvider = fallback.name;
      return await fallback.chat(messages, task);
    }
  }
}
