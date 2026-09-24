/**
 * 智护同行 - 病历采集服务
 *
 * 把处方单/检查单照片识别成结构化的“待确认”记录，用户确认后才写入正式病历。
 * 流程：选图/拍照 → 缩放解码 → 系统 OCR → 大模型（或离线规则）整理字段 → 待确认卡片
 *
 * 系统文字识别不支持 DevEco 模拟器，此时返回 OCR_UNAVAILABLE，页面会引导“手动录入”。
 */

import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { ServiceRecord, RecordSource } from '../core/AgentTypes';
import { DateUtil } from '../core/DateUtil';
import { LLMService, LLMMessage, LLMTask } from './LLMService';

export interface OcrProvider {
  /** 传入图片 PixelMap，返回识别出的原始文字 */
  recognizeText(pixelMap: image.PixelMap): Promise<string>;
  release(): Promise<void>;
}

/** 采集结果：record 为空时 reason 说明原因，页面据此提示 */
export interface OcrOutcome {
  record: ServiceRecord | null;
  reason: string;   // OK / CANCELLED / LOAD_FAILED / OCR_UNAVAILABLE / NO_TEXT / NOT_RECORD
}

/** 系统 OCR（Core Vision Kit），不支持模拟器 */
export class SystemOcrProvider implements OcrProvider {
  private initialized: boolean = false;

  async recognizeText(pixelMap: image.PixelMap): Promise<string> {
    if (!this.initialized) {
      await textRecognition.init();
      this.initialized = true;
    }
    const visionInfo: textRecognition.VisionInfo = { pixelMap: pixelMap };
    const configuration: textRecognition.TextRecognitionConfiguration = {
      isDirectionDetectionSupported: true
    };
    const result: textRecognition.TextRecognitionResult =
      await textRecognition.recognizeText(visionInfo, configuration);
    return result.value;
  }

  async release(): Promise<void> {
    if (!this.initialized) {
      return;
    }
    await textRecognition.release();
    this.initialized = false;
  }
}

/** 第三方 OCR HTTP 接口（备选，需自行申请并按其文档改造请求体） */
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
      const helper: util.Base64Helper = new util.Base64Helper();
      const base64: string = helper.encodeToStringSync(new Uint8Array(buffer));
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
        const text: Object | undefined = obj['text'];
        return typeof text === 'string' ? text : '';
      } finally {
        req.destroy();
      }
    } finally {
      imagePacker.release();
    }
  }

  async release(): Promise<void> {
    // 无长生命周期资源
  }
}

/** 无 OCR 能力时的占位实现 */
export class MockOcrProvider implements OcrProvider {
  async recognizeText(pixelMap: image.PixelMap): Promise<string> {
    throw new Error('OCR_UNAVAILABLE');
  }

  async release(): Promise<void> {
    // 无资源
  }
}

const STRUCTURE_PROMPT: string = `你是病历信息整理助手。下面是一张处方单或检查单拍照识别出的原始文字，
可能包含换行错乱、识别噪音，请从中提取关键信息，只输出 json 对象，不要输出其他文字：
{
  "hospital": "医院名称，识别不到则空字符串",
  "department": "科室，识别不到则空字符串",
  "doctorName": "医生姓名，识别不到则空字符串",
  "visitDate": "就诊日期 YYYY-MM-DD，识别不到则空字符串",
  "followUpDays": 医嘱复诊间隔天数（数字，没提到则填0）,
  "prescription": "药品名称与用法用量，原样摘录，没有则空字符串"
}
只提取原文明确出现的内容，不要根据常识补全或猜测；身份证号、医保卡号等敏感号码不要写入任何字段。`;

/** 解码时长边最多 2048 像素，避免大图占用过多内存 */
const MAX_EDGE: number = 2048;

export class OcrCaptureService {
  private static ocrProvider: OcrProvider = new MockOcrProvider();

  static setProvider(p: OcrProvider): void {
    OcrCaptureService.ocrProvider = p;
  }

  static async release(): Promise<void> {
    try {
      await OcrCaptureService.ocrProvider.release();
    } catch (e) {
      console.warn(`[OcrCapture] release failed: ${e}`);
    }
  }

  /** 打开系统图库选择器（第一格可直接拍照），返回图片 uri；取消返回空串 */
  static async pickPhoto(): Promise<string> {
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    options.isPhotoTakingSupported = true;
    const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
    if (result.photoUris.length === 0) {
      return '';
    }
    return result.photoUris[0];
  }

  /** 主入口：从图片 uri 生成一条待确认记录 */
  static async captureFromUri(uri: string): Promise<OcrOutcome> {
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await OcrCaptureService.decode(uri);
    } catch (e) {
      console.error(`[OcrCapture] decode failed: ${e}`);
      return OcrCaptureService.outcome(null, 'LOAD_FAILED');
    }

    let rawText: string = '';
    try {
      rawText = await OcrCaptureService.ocrProvider.recognizeText(pixelMap);
    } catch (e) {
      console.error(`[OcrCapture] OCR failed: ${e}`);
      return OcrCaptureService.outcome(null, 'OCR_UNAVAILABLE');
    } finally {
      pixelMap.release().catch((err: Error) => {
        console.warn(`[OcrCapture] pixelmap release failed: ${err.message}`);
      });
    }
    if (rawText.trim().length === 0) {
      return OcrCaptureService.outcome(null, 'NO_TEXT');
    }

    const messages: LLMMessage[] = [
      { role: 'system', content: STRUCTURE_PROMPT },
      { role: 'user', content: rawText }
    ];
    const raw: string = await LLMService.chat(messages, LLMTask.RECORD_EXTRACT);
    const record: ServiceRecord | null = OcrCaptureService.safeParse(raw);
    return OcrCaptureService.outcome(record, record === null ? 'NOT_RECORD' : 'OK');
  }

  private static async decode(uri: string): Promise<image.PixelMap> {
    const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const source: image.ImageSource = image.createImageSource(file.fd);
      try {
        const info: image.ImageInfo = await source.getImageInfo();
        const longEdge: number = Math.max(info.size.width, info.size.height);
        const options: image.DecodingOptions = {};
        if (longEdge > MAX_EDGE) {
          const scale: number = MAX_EDGE / longEdge;
          options.desiredSize = {
            width: Math.round(info.size.width * scale),
            height: Math.round(info.size.height * scale)
          };
        }
        return await source.createPixelMap(options);
      } finally {
        source.release().catch((err: Error) => {
          console.warn(`[OcrCapture] source release failed: ${err.message}`);
        });
      }
    } finally {
      await fileIo.close(file.fd);
    }
  }

  private static outcome(record: ServiceRecord | null, reason: string): OcrOutcome {
    const o: OcrOutcome = { record: record, reason: reason };
    return o;
  }

  private static str(obj: Record<string, Object>, key: string): string {
    const v: Object | undefined = obj[key];
    return typeof v === 'string' ? v.trim() : '';
  }

  private static safeParse(raw: string): ServiceRecord | null {
    const start: number = raw.indexOf('{');
    const end: number = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(raw.substring(start, end + 1)) as Record<string, Object>;
      const fu: Object | undefined = obj['followUpDays'];
      const fuNum: number = typeof fu === 'number' ? fu : Number(fu);
      let visitDate: string = OcrCaptureService.str(obj, 'visitDate');
      if (!DateUtil.isValidYmd(visitDate)) {
        visitDate = DateUtil.normalizeYmd(visitDate);
      }
      const record: ServiceRecord = {
        recordId: `ocr_${Date.now()}`,
        hospital: OcrCaptureService.str(obj, 'hospital'),
        department: OcrCaptureService.str(obj, 'department'),
        doctorName: OcrCaptureService.str(obj, 'doctorName'),
        visitDate: visitDate,
        followUpDays: isFinite(fuNum) && fuNum > 0 ? Math.round(fuNum) : 0,
        prescription: OcrCaptureService.str(obj, 'prescription'),
        source: RecordSource.OCR_SCAN,
        confirmed: false   // 识别出来的都是“待确认”，不能直接当真
      };
      if (record.hospital.length === 0 && record.prescription.length === 0) {
        return null;
      }
      return record;
    } catch (e) {
      console.error(`[OcrCapture] parse failed: ${e}`);
      return null;
    }
  }
}
