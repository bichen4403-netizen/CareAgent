/**
 * 智护同行 - 页面文案工具
 * 数据来源、设备、阶段等枚举值统一翻译成老人看得懂的话，各页面共用。
 */

import { DataSourceType, JourneyStage, RecordSource } from '../core/AgentTypes';

export class UiLabels {

  static source(source: string): string {
    if (source === DataSourceType.REALTIME_API || source === DataSourceType.OFFICIAL) {
      return '实时数据';
    }
    if (source === DataSourceType.DEMO) {
      return '演示数据';
    }
    if (source === DataSourceType.FALLBACK) {
      return '降级数据';
    }
    if (source === DataSourceType.USER_CONFIRMED) {
      return '您已确认';
    }
    if (source === DataSourceType.LOCAL_COMPUTED) {
      return '本机估算';
    }
    return '';
  }

  /** 演示/降级/估算用暖色提示，实时数据用绿色 */
  static sourceColor(source: string): string {
    if (source === DataSourceType.REALTIME_API || source === DataSourceType.OFFICIAL ||
      source === DataSourceType.USER_CONFIRMED) {
      return '#3B7A57';
    }
    return '#A65A2E';
  }

  static device(device: string): string {
    if (device === 'watch') {
      return '手机 + 手表';
    }
    if (device === 'earphone') {
      return '耳机语音';
    }
    return '手机';
  }

  static stage(stage: string): string {
    if (stage === JourneyStage.DRAFT) {
      return '待确认挂号';
    }
    if (stage === JourneyStage.AWAITING_OFFICIAL) {
      return '等您确认挂号结果';
    }
    if (stage === JourneyStage.CONFIRMED) {
      return '已确认 · 提醒已开启';
    }
    if (stage === JourneyStage.COMPLETED) {
      return '已完成';
    }
    return '已取消';
  }

  static recordSource(source: string): string {
    if (source === RecordSource.OCR_SCAN) {
      return '拍照识别';
    }
    if (source === RecordSource.POST_VISIT_ASK) {
      return '看完病记录';
    }
    if (source === RecordSource.USER_SPOKEN) {
      return '口述';
    }
    return '手动录入';
  }

  static followUp(days: number): string {
    if (days <= 0) {
      return '无需复诊';
    }
    if (days % 30 === 0) {
      return `${days / 30}个月后复诊`;
    }
    if (days % 7 === 0) {
      return `${days / 7}周后复诊`;
    }
    return `${days}天后复诊`;
  }

  static taskStatus(status: string): string {
    if (status === 'SUCCESS') {
      return '已完成';
    }
    if (status === 'RUNNING') {
      return '处理中';
    }
    if (status === 'FAILED') {
      return '未成功';
    }
    if (status === 'SKIPPED') {
      return '已跳过';
    }
    return '等待中';
  }

  static taskIcon(status: string): string {
    if (status === 'SUCCESS') {
      return '✓';
    }
    if (status === 'RUNNING') {
      return '◐';
    }
    if (status === 'FAILED') {
      return '!';
    }
    if (status === 'SKIPPED') {
      return '–';
    }
    return '○';
  }
}
