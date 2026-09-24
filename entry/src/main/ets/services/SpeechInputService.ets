/**
 * 智护同行 - 语音输入（系统离线语音识别）
 *
 * 采用识别引擎自带录音的“实时录音识别”模式（recognitionMode = 0）：
 *   - 不再自己创建录音器、切分音频块，避免音频块大小不符合引擎要求导致识别失败
 *   - 引擎内置语音端点检测：老人说完停顿约 1.5 秒自动结束；开口前 4 秒没说话也会结束
 *   - 用户也可以再点一次按钮主动结束（finish）
 * 识别过程中通过 onPartial 回调实时显示“正在听到的内容”。
 *
 * 失败时抛出带错误码前缀的 Error，页面据此给出不同提示：
 *   ENGINE_UNAVAILABLE —— 设备不支持（常见于模拟器），可切换到文字或示例
 *   BUSY               —— 上一次识别还没结束
 */

import { speechRecognizer } from '@kit.CoreSpeechKit';

export type PartialCallback = (text: string) => void;

const MAX_LISTEN_MS: number = 22000;

export class SpeechInputService {
  private static engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private static sessionId: string = '';
  private static active: boolean = false;
  private static finalText: string = '';
  private static partialText: string = '';
  private static resolver: ((text: string) => void) | null = null;
  private static timer: number = -1;

  static isActive(): boolean {
    return SpeechInputService.active;
  }

  /**
   * 开始识别，Promise 在识别结束时返回最终文字（可能为空串）。
   * 调用前需确保已获得麦克风权限。
   */
  static async start(onPartial: PartialCallback): Promise<string> {
    if (SpeechInputService.active) {
      throw new Error('BUSY');
    }
    SpeechInputService.active = true;
    SpeechInputService.finalText = '';
    SpeechInputService.partialText = '';
    SpeechInputService.sessionId = `zht_asr_${Date.now()}`;

    try {
      if (SpeechInputService.engine === null) {
        const extraParam: Record<string, Object> = { 'locate': 'CN', 'recognizerMode': 'short' };
        const params: speechRecognizer.CreateEngineParams = {
          language: 'zh-CN',
          online: 1,       // 1 = 离线识别
          extraParams: extraParam
        };
        SpeechInputService.engine = await speechRecognizer.createEngine(params);
      }
    } catch (e) {
      SpeechInputService.active = false;
      SpeechInputService.engine = null;
      console.error(`[ASR] create engine failed: ${e}`);
      throw new Error('ENGINE_UNAVAILABLE');
    }

    const engine: speechRecognizer.SpeechRecognitionEngine = SpeechInputService.engine as speechRecognizer.SpeechRecognitionEngine;
    return new Promise<string>((resolve: (text: string) => void) => {
      SpeechInputService.resolver = resolve;
      const listener: speechRecognizer.RecognitionListener = {
        onStart: (sessionId: string, eventMessage: string) => {
          console.info(`[ASR] start ${sessionId}`);
        },
        onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {
          console.info(`[ASR] event ${eventCode}: ${eventMessage}`);
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
          if (sessionId !== SpeechInputService.sessionId) {
            return;
          }
          if (result.isFinal) {
            SpeechInputService.finalText += result.result;
            SpeechInputService.partialText = '';
          } else {
            SpeechInputService.partialText = result.result;
          }
          onPartial(SpeechInputService.currentText());
          if (result.isLast) {
            SpeechInputService.complete();
          }
        },
        onComplete: (sessionId: string, eventMessage: string) => {
          if (sessionId === SpeechInputService.sessionId) {
            SpeechInputService.complete();
          }
        },
        onError: (sessionId: string, errorCode: number, errorMessage: string) => {
          console.error(`[ASR] error ${errorCode}: ${errorMessage}`);
          if (sessionId === SpeechInputService.sessionId) {
            SpeechInputService.complete();
          }
        }
      };
      try {
        engine.setListener(listener);
        const audioInfo: speechRecognizer.AudioInfo = {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        };
        const extra: Record<string, Object> = {
          'recognitionMode': 0,      // 0 = 引擎自行录音（需要麦克风权限）
          'vadBegin': 4000,          // 开口前最多等 4 秒
          'vadEnd': 1500,            // 说完停顿 1.5 秒自动结束，老人语速慢
          'maxAudioDuration': 20000
        };
        const startParams: speechRecognizer.StartParams = {
          sessionId: SpeechInputService.sessionId,
          audioInfo: audioInfo,
          extraParams: extra
        };
        engine.startListening(startParams);
        SpeechInputService.timer = setTimeout(() => {
          SpeechInputService.finish();
        }, MAX_LISTEN_MS);
      } catch (e) {
        console.error(`[ASR] start listening failed: ${e}`);
        SpeechInputService.complete();
      }
    });
  }

  /** 用户主动结束：让引擎尽快给出最终结果 */
  static finish(): void {
    if (!SpeechInputService.active || SpeechInputService.engine === null) {
      return;
    }
    try {
      SpeechInputService.engine.finish(SpeechInputService.sessionId);
    } catch (e) {
      console.warn(`[ASR] finish failed: ${e}`);
      SpeechInputService.complete();
      return;
    }
    // 引擎 2 秒内没有回调也强制结束，避免按钮卡在“正在听”
    setTimeout(() => {
      if (SpeechInputService.active) {
        SpeechInputService.complete();
      }
    }, 2000);
  }

  /** 放弃本次识别（页面离开时调用） */
  static cancel(): void {
    if (SpeechInputService.active && SpeechInputService.engine !== null) {
      try {
        SpeechInputService.engine.cancel(SpeechInputService.sessionId);
      } catch (e) {
        console.warn(`[ASR] cancel failed: ${e}`);
      }
    }
    SpeechInputService.finalText = '';
    SpeechInputService.partialText = '';
    SpeechInputService.complete();
  }

  static release(): void {
    SpeechInputService.cancel();
    if (SpeechInputService.engine !== null) {
      try {
        SpeechInputService.engine.shutdown();
      } catch (e) {
        console.warn(`[ASR] shutdown failed: ${e}`);
      }
      SpeechInputService.engine = null;
    }
  }

  private static currentText(): string {
    return (SpeechInputService.finalText + SpeechInputService.partialText).trim();
  }

  private static complete(): void {
    if (SpeechInputService.timer >= 0) {
      clearTimeout(SpeechInputService.timer);
      SpeechInputService.timer = -1;
    }
    const text: string = SpeechInputService.currentText();
    SpeechInputService.active = false;
    const resolve: ((text: string) => void) | null = SpeechInputService.resolver;
    SpeechInputService.resolver = null;
    if (resolve !== null) {
      resolve(text);
    }
  }
}
