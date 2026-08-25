/**
 * 智护同行 - 病历采集服务
 *
 * 职责：把用户拍的处方单/检查单照片，识别成结构化的 ServiceRecord，
 * 但不直接写入正式病历 —— 识别结果必须先经用户确认（见 ContextStore.confirmRecord）。
 *
 * 流程：拍照 → OCR 识别出文字 → 大模型把文字整理成结构化字段 → 生成待确认记录
 *
 * ⚠️ 配置说明：
 * OCR 能力优先使用 HarmonyOS 系统自带的文字识别（Core Vision Kit）。
 * 不同 SDK 版本 API 名称可能有差异，请对照本地 DevEco 版本的
 * @kit.CoreVisionKit 文档核实具体接口名，本文件已把调用收敛在
 * SystemOcrProvider 一处，接口对不上时只需改这一个类。
 * 也提供了 HttpOcrProvider，可接讯飞/百度等第三方 OCR 服务作为备选。
 */

import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ServiceRecord, RecordSource } from '../core/AgentTypes';
import { LLMService, LLMMessage } from './LLMService';

export interface OcrProvider {
  /** 传入图片 PixelMap，返回识别出的原始文字（不做结构化，只是纯文本） */
  recognizeText(pixelMap: image.PixelMap): Promise<string>;
}

/**
 * 系统 OCR（优先使用）
 * TODO: 对照本地 SDK 版本核实 @kit.CoreVisionKit 的具体 API，
 * 目前 HarmonyOS 5.x 起提供文字识别能力，函数名以官方文档为准。
 */
export class SystemOcrProvider implements OcrProvider {
  async recognizeText(pixelMap: image.PixelMap): Promise<string> {
    // TODO: 替换为真实调用，示例（具体以官方文档为准）：
    // import { textRecognition } from '@kit.CoreVisionKit';
    // const result = await textRecognition.recognizeText({ pixelMap });
    // return result.text ?? result.value?.map(b => b.text).join('\n') ?? '';
    throw new Error('SystemOcrProvider not wired yet, see TODO in OcrCaptureService.ets');
  }
}

/** 第三方 OCR HTTP 接口（备选方案，讯飞/百度等，需自行申请 Key 并按其文档改造请求体） */
export class HttpOcrProvider implements OcrProvider {
  private endpoint: string;
  private apiKey: string;

  constructor(endpoint: string, apiKey: string) {
    this.endpoint = endpoint;
    this.apiKey = apiKey;
  }

  async recognizeText(pixelMap: image.PixelMap): Promise<string> {
    const imagePacker: image.ImagePacker = image.createImagePacker();
    try {
      const buffer: ArrayBuffer = await imagePacker.packing(pixelMap, { format: 'image/jpeg', quality: 90 });
      const base64: string = HttpOcrProvider.arrayBufferToBase64(buffer);

      const req: http.HttpRequest = http.createHttp();
      try {
        const bodyObj: Record<string, Object> = { 'image': base64 };
        const resp: http.HttpResponse = await req.request(this.endpoint, {
          method: http.RequestMethod.POST,
          header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.apiKey}` },
          extraData: JSON.stringify(bodyObj),
          connectTimeout: 10000,
          readTimeout: 20000
        });
        if (resp.responseCode !== 200) {
          throw new Error(`OCR HTTP ${resp.responseCode}`);
        }
        const obj: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
        return (obj['text'] as string) ?? '';
      } finally {
        req.destroy();
      }
    } finally {
      imagePacker.release();
    }
  }

  /** 用系统 Base64Helper 编码，避免用方括号动态取全局属性（ArkTS 不支持这种写法） */
  private static arrayBufferToBase64(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes);
  }
}

/** 离线兜底：拿不到 OCR 能力时返回空文本，走人工输入兜底 */
export class MockOcrProvider implements OcrProvider {
  async recognizeText(pixelMap: image.PixelMap): Promise<string> {
    return '';
  }
}

const STRUCTURE_PROMPT: string = `你是病历信息整理助手。下面是一张处方单或检查单拍照识别出的原始文字，
可能包含换行错乱、识别噪音，请从中提取关键信息，输出 JSON，不要输出其他文字：
{
  "hospital": "医院名称，识别不到则空字符串",
  "department": "科室，识别不到则空字符串",
  "doctorName": "医生姓名，识别不到则空字符串",
  "visitDate": "就诊日期 YYYY-MM-DD，识别不到则空字符串",
  "followUpDays": "医嘱复诊间隔天数，数字，没提到则填0",
  "prescription": "药品名称与用法用量，原样摘录，没有则空字符串"
}`;

export class OcrCaptureService {
  private static ocrProvider: OcrProvider = new MockOcrProvider();

  static setProvider(p: OcrProvider): void {
    OcrCaptureService.ocrProvider = p;
  }

  /**
   * 主入口：拍照 → OCR → 大模型结构化 → 生成一条"待确认"记录
   * 调用方（UI 层）必须在用户确认后才调用 ContextStore.confirmRecord()，
   * 这里只负责生成候选数据，不直接写入正式病历
   */
  static async captureFromPhoto(pixelMap: image.PixelMap): Promise<ServiceRecord | null> {
    let rawText: string = '';
    try {
      rawText = await OcrCaptureService.ocrProvider.recognizeText(pixelMap);
    } catch (e) {
      console.error(`[OcrCaptureService] OCR failed: ${e}`);
      return null;
    }

    if (rawText.trim().length === 0) {
      return null;
    }

    const messages: LLMMessage[] = [
      { role: 'system', content: STRUCTURE_PROMPT },
      { role: 'user', content: rawText }
    ];
    const raw: string = await LLMService.chat(messages);

    return OcrCaptureService.safeParse(raw);
  }

  private static safeParse(raw: string): ServiceRecord | null {
    let jsonStr: string = raw.trim();
    const start: number = jsonStr.indexOf('{');
    const end: number = jsonStr.lastIndexOf('}');
    if (start >= 0 && end > start) {
      jsonStr = jsonStr.substring(start, end + 1);
    }
    try {
      const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
      const record: ServiceRecord = {
        recordId: `ocr_${Date.now()}`,
        hospital: (obj['hospital'] as string) ?? '',
        department: (obj['department'] as string) ?? '',
        doctorName: (obj['doctorName'] as string) ?? '',
        visitDate: (obj['visitDate'] as string) ?? '',
        followUpDays: Number(obj['followUpDays'] ?? 0),
        prescription: (obj['prescription'] as string) ?? '',
        source: RecordSource.OCR_SCAN,
        confirmed: false   // 关键：识别出来的都是"待确认"，不能直接当真
      };
      // 关键字段都识别不出来，大概率是拍糊了或不是处方单，直接判失败
      if (record.hospital.length === 0 && record.prescription.length === 0) {
        return null;
      }
      return record;
    } catch (e) {
      console.error(`[OcrCaptureService] parse failed: ${e}`);
      return null;
    }
  }

  /**
   * 陪诊结束后系统主动询问（对话口述场景）
   * 同样生成"待确认"记录，不是"拍照"来源
   */
  static buildFromUserSpeech(hospital: string, department: string, doctorName: string,
                             visitDate: string, prescription: string,
                             followUpDays: number): ServiceRecord {
    return {
      recordId: `spoken_${Date.now()}`,
      hospital: hospital,
      department: department,
      doctorName: doctorName,
      visitDate: visitDate,
      followUpDays: followUpDays,
      prescription: prescription,
      source: RecordSource.POST_VISIT_ASK,
      confirmed: false
    };
  }
}
