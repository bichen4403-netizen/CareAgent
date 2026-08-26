import http from "@ohos:net.http";
export interface LLMMessage {
    role: string; // system / user / assistant
    content: string;
}
export interface LLMProvider {
    chat(messages: LLMMessage[]): Promise<string>;
}
// ==================== HTTP 实现 ====================
export class HttpLLMProvider implements LLMProvider {
    private endpoint: string;
    private token: string;
    private model: string;
    constructor(endpoint: string, token: string, model: string) {
        this.endpoint = endpoint;
        this.token = token;
        this.model = model;
    }
    async chat(messages: LLMMessage[]): Promise<string> {
        const req: http.HttpRequest = http.createHttp();
        try {
            const bodyObj: Record<string, Object> = {
                'model': this.model,
                'messages': messages,
                'temperature': 0.2,
                'stream': false
            };
            const headers: Record<string, string> = {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${this.token}`
            };
            const resp: http.HttpResponse = await req.request(this.endpoint, {
                method: http.RequestMethod.POST,
                header: headers,
                extraData: JSON.stringify(bodyObj),
                connectTimeout: 10000,
                readTimeout: 30000
            });
            if (resp.responseCode !== 200) {
                throw new Error(`LLM HTTP ${resp.responseCode}`);
            }
            return HttpLLMProvider.extractContent(resp.result as string);
        }
        finally {
            req.destroy();
        }
    }
    /** 兼容 OpenAI 风格返回结构，解析失败则原样返回 */
    private static extractContent(raw: string): string {
        try {
            const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
            const choices = obj['choices'] as Array<Record<string, Object>>;
            if (choices !== undefined && choices.length > 0) {
                const msg = choices[0]['message'] as Record<string, string>;
                if (msg !== undefined && msg['content'] !== undefined) {
                    return msg['content'];
                }
            }
        }
        catch (e) {
            console.warn(`[LLM] parse fallback: ${e}`);
        }
        return raw;
    }
}
// ==================== Mock 实现（离线演示兜底） ====================
export class MockLLMProvider implements LLMProvider {
    async chat(messages: LLMMessage[]): Promise<string> {
        let userText: string = '';
        for (let i = messages.length - 1; i >= 0; i--) {
            if (messages[i].role === 'user') {
                userText = messages[i].content;
                break;
            }
        }
        await MockLLMProvider.delay(300);
        return MockLLMProvider.ruleBasedIntent(userText);
    }
    private static delay(ms: number): Promise<void> {
        return new Promise<void>((resolve: () => void) => {
            setTimeout(resolve, ms);
        });
    }
    /** 关键词规则兜底：无网络或模型超时时保证流程不中断 */
    private static ruleBasedIntent(text: string): string {
        let type: string = 'UNKNOWN';
        if (text.indexOf('药') >= 0 || text.indexOf('续方') >= 0) {
            type = 'MEDICINE_REFILL';
        }
        else if (text.indexOf('报告') >= 0 || text.indexOf('化验') >= 0) {
            type = 'REPORT_QUERY';
        }
        else if (text.indexOf('医院') >= 0 || text.indexOf('复查') >= 0 ||
            text.indexOf('看病') >= 0 || text.indexOf('挂号') >= 0 ||
            text.indexOf('就诊') >= 0 || text.indexOf('复诊') >= 0) {
            type = 'MEDICAL_VISIT';
        }
        let hospital: string = '';
        const hIdx: number = text.indexOf('医院');
        if (hIdx > 0) {
            const start: number = Math.max(0, hIdx - 10);
            hospital = text.substring(start, hIdx + 2);
            const cut: number = hospital.search(/[去到在]/);
            if (cut >= 0) {
                hospital = hospital.substring(cut + 1);
            }
        }
        let department: string = '';
        if (text.indexOf('高血压') >= 0 || text.indexOf('血压') >= 0 || text.indexOf('心') >= 0) {
            department = '心血管内科';
        }
        else if (text.indexOf('糖尿病') >= 0 || text.indexOf('血糖') >= 0) {
            department = '内分泌科';
        }
        else if (text.indexOf('骨') >= 0 || text.indexOf('腿') >= 0 || text.indexOf('膝') >= 0) {
            department = '骨科';
        }
        else if (text.indexOf('眼') >= 0) {
            department = '眼科';
        }
        let expectedDate: string = '';
        if (text.indexOf('明天') >= 0) {
            expectedDate = MockLLMProvider.dateAfter(1);
        }
        else if (text.indexOf('后天') >= 0) {
            expectedDate = MockLLMProvider.dateAfter(2);
        }
        else if (text.indexOf('下周') >= 0) {
            expectedDate = MockLLMProvider.dateAfter(7);
        }
        else if (text.indexOf('今天') >= 0) {
            expectedDate = MockLLMProvider.dateAfter(0);
        }
        const isRevisit: boolean = text.indexOf('复查') >= 0 || text.indexOf('复诊') >= 0 ||
            text.indexOf('拿药') >= 0 || text.indexOf('取药') >= 0;
        const missing: string[] = [];
        if (hospital.length === 0) {
            missing.push('hospital');
        }
        const result: Record<string, Object> = {
            'type': type,
            'hospital': hospital,
            'department': department,
            'purpose': text,
            'expectedDate': expectedDate,
            'isRevisit': isRevisit,
            'confidence': type === 'UNKNOWN' ? 0.3 : 0.85,
            'missingSlots': missing
        };
        return JSON.stringify(result);
    }
    private static dateAfter(days: number): string {
        const d: Date = new Date(Date.now() + days * 24 * 3600 * 1000);
        const m: string = `${d.getMonth() + 1}`.padStart(2, '0');
        const day: string = `${d.getDate()}`.padStart(2, '0');
        return `${d.getFullYear()}-${m}-${day}`;
    }
}
// ==================== 单例管理 ====================
export class LLMService {
    private static provider: LLMProvider = new MockLLMProvider();
    /** App 启动时按配置注入真实 Provider */
    static setProvider(p: LLMProvider): void {
        LLMService.provider = p;
    }
    static async chat(messages: LLMMessage[]): Promise<string> {
        try {
            return await LLMService.provider.chat(messages);
        }
        catch (e) {
            console.error(`[LLMService] failed, fallback to mock: ${e}`);
            const fallback: MockLLMProvider = new MockLLMProvider();
            return await fallback.chat(messages);
        }
    }
}
