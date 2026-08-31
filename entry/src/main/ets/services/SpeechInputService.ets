/**
 * HarmonyOS 离线语音输入。
 *
 * 真机具备 CoreSpeechKit 和麦克风权限时，采集 PCM 音频并交给系统识别；
 * Preview/模拟器不具备语音能力时由页面回退到演示语料，不影响主流程。
 */
import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';

export class SpeechInputService {
  private static engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private static capturer: audio.AudioCapturer | null = null;
  private static sessionId: string = '';
  private static timerId: number = -1;
  private static finalText: string = '';
  private static pendingResolve: ((text: string) => void) | null = null;
  private static completed: boolean = false;

  static async start(): Promise<string> {
    await SpeechInputService.cleanup();
    SpeechInputService.sessionId = `speech_${Date.now()}`;
    SpeechInputService.finalText = '';
    SpeechInputService.completed = false;

    const promise: Promise<string> = new Promise<string>((resolve: (text: string) => void) => {
      SpeechInputService.pendingResolve = resolve;
    });

    try {
      SpeechInputService.engine = await speechRecognizer.createEngine({
        language: 'zh-CN',
        online: 1,
        extraParams: { 'locate': 'CN', 'recognizerMode': 'short' }
      });
      SpeechInputService.engine.setListener({
        onStart: (sessionId: string, message: string): void => {
          console.info(`[SpeechInput] start ${sessionId}: ${message}`);
        },
        onEvent: (sessionId: string, eventCode: number, message: string): void => {
          console.info(`[SpeechInput] event ${sessionId}/${eventCode}: ${message}`);
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (sessionId !== SpeechInputService.sessionId) {
            return;
          }
          if (result.result !== undefined && result.result.trim().length > 0) {
            SpeechInputService.finalText = result.result.trim();
          }
          if (result.isLast && result.isFinal) {
            SpeechInputService.complete(SpeechInputService.finalText);
          }
        },
        onComplete: (sessionId: string, message: string): void => {
          console.info(`[SpeechInput] complete ${sessionId}: ${message}`);
          SpeechInputService.complete(SpeechInputService.finalText);
        },
        onError: (sessionId: string, errorCode: number, message: string): void => {
          console.warn(`[SpeechInput] error ${sessionId}/${errorCode}: ${message}`);
          SpeechInputService.complete(SpeechInputService.finalText);
        }
      });

      SpeechInputService.capturer = await audio.createAudioCapturer({
        streamInfo: {
          samplingRate: 16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
          capturerFlags: 0
        }
      });
      SpeechInputService.capturer.on('readData', (buffer: ArrayBuffer): void => {
        if (SpeechInputService.engine !== null && !SpeechInputService.completed) {
          SpeechInputService.engine.writeAudio(
            SpeechInputService.sessionId, new Uint8Array(buffer)
          );
        }
      });

      SpeechInputService.engine.startListening({
        sessionId: SpeechInputService.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      await SpeechInputService.capturer.start();
      SpeechInputService.timerId = setTimeout(() => {
        SpeechInputService.complete(SpeechInputService.finalText);
      }, 8000);
    } catch (e) {
      await SpeechInputService.cleanup();
      SpeechInputService.resolvePending('');
      throw new Error(String(e));
    }
    return promise;
  }

  static async cancel(): Promise<void> {
    SpeechInputService.completed = true;
    await SpeechInputService.cleanup();
    SpeechInputService.resolvePending('');
  }

  private static complete(text: string): void {
    if (SpeechInputService.completed) {
      return;
    }
    SpeechInputService.completed = true;
    SpeechInputService.cleanup().then(() => {
      SpeechInputService.resolvePending(text.trim());
    }).catch(() => {
      SpeechInputService.resolvePending(text.trim());
    });
  }

  private static resolvePending(text: string): void {
    const resolve: ((value: string) => void) | null = SpeechInputService.pendingResolve;
    SpeechInputService.pendingResolve = null;
    if (resolve !== null) {
      resolve(text);
    }
  }

  private static async cleanup(): Promise<void> {
    if (SpeechInputService.timerId >= 0) {
      clearTimeout(SpeechInputService.timerId);
      SpeechInputService.timerId = -1;
    }
    if (SpeechInputService.capturer !== null) {
      try {
        SpeechInputService.capturer.off('readData');
        if (SpeechInputService.capturer.state !== audio.AudioState.STATE_RELEASED) {
          await SpeechInputService.capturer.stop();
          await SpeechInputService.capturer.release();
        }
      } catch (e) {
        console.warn(`[SpeechInput] capturer cleanup failed: ${e}`);
      }
      SpeechInputService.capturer = null;
    }
    if (SpeechInputService.engine !== null) {
      try {
        if (SpeechInputService.sessionId.length > 0 && SpeechInputService.engine.isBusy()) {
          SpeechInputService.engine.cancel(SpeechInputService.sessionId);
        }
        SpeechInputService.engine.shutdown();
      } catch (e) {
        console.warn(`[SpeechInput] engine cleanup failed: ${e}`);
      }
      SpeechInputService.engine = null;
    }
  }
}
