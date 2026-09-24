/**
 * 智护同行 - 出行 Agent
 *
 * 职责：读取医疗 Agent 在黑板上的挂号时间，倒推建议出发时间。
 *   出发时间 = 就诊时间 − 车程 − 预留时间（取号排队 20 分钟 + 天气/路况额外预留）
 * 天气取“就诊当天”的预报（不是今天的天气）；车程优先用网关的实时路线。
 * 暴雨等恶劣天气由中枢识别为异常，重规划时本 Agent 会加大预留并建议打车。
 */

import {
  AgentResult, TaskNode, RuntimeContext, Appointment, TravelPlan, DataSourceType, VerificationStatus
} from '../core/AgentTypes';
import { BaseAgent } from './BaseAgent';
import { blackboard } from '../core/EventBus';
import { DateUtil } from '../core/DateUtil';
import { TravelService, DrivingResult } from '../services/TravelService';
import { WeatherService, WeatherInfo } from '../services/WeatherService';

/** 到院后取号、排队、找诊室的基础预留 */
const BASE_BUFFER_MIN: number = 20;

export class TravelAgent extends BaseAgent {
  readonly name: string = 'TravelAgent';

  protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    const medical: AgentResult | undefined = blackboard.getResult('T1');
    if (medical === undefined || !medical.success) {
      return this.fail(task.id, '还没确定看病时间，暂时没法规划出行', 'NO_APPOINTMENT');
    }
    const md: Record<string, Object> = BaseAgent.parseRecord(medical.data);
    const apptObj: Object | undefined = md['appointment'];
    if (apptObj === undefined || apptObj === null) {
      return this.fail(task.id, '挂号信息不完整，暂时没法规划出行', 'BAD_APPOINTMENT');
    }
    const appt: Appointment = apptObj as Appointment;
    const visitTs: number = DateUtil.toTimestamp(appt.visitDate, appt.visitTime);
    if (isNaN(visitTs)) {
      return this.fail(task.id, '看病时间格式不对，暂时没法规划出行', 'BAD_VISIT_TIME');
    }

    const payload: Record<string, Object> = BaseAgent.payloadOf(task);
    const anomaly: Record<string, Object> | null = BaseAgent.anomalyOf(payload);
    const stormAlert: boolean = anomaly !== null && BaseAgent.strOf(anomaly, 'anomalyType') === 'HEAVY_RAIN';

    // 天气预报与路线并发查询
    const weatherTask: Promise<WeatherInfo> = WeatherService.getForDate(rt.currentLng, rt.currentLat, appt.visitDate);
    const driveTask: Promise<DrivingResult> = TravelService.getDriving(rt.currentLng, rt.currentLat,
      appt.hospitalAddress, appt.hospitalLng, appt.hospitalLat);
    const weatherInfo: WeatherInfo = await weatherTask;
    const drive: DrivingResult = await driveTask;

    let weather: string = weatherInfo.weather;
    if (stormAlert) {
      const detail: string = BaseAgent.strOf(anomaly as Record<string, Object>, 'detail');
      weather = detail.length > 0 ? `${detail}（预警）` : '暴雨（预警）';
    }

    let buffer: number = BASE_BUFFER_MIN;
    const severe: boolean = /暴雨|大雨|大暴雨|暴雪|大雪|冰雹|台风|预警/.test(weather);
    if (severe) {
      buffer += 25;
    } else if (/雨|雪|雾|霾/.test(weather)) {
      buffer += 10;
    }
    if (drive.trafficLevel === '拥堵' || drive.trafficLevel === '严重拥堵') {
      buffer += 15;
    } else if (drive.trafficLevel === '缓行') {
      buffer += 5;
    }

    // 出发时间向下取整到 5 分钟，方便老人记
    let departTs: number = visitTs - (drive.durationMin + buffer) * 60 * 1000;
    const fiveMin: number = 5 * 60 * 1000;
    departTs = Math.floor(departTs / fiveMin) * fiveMin;

    const tips: string[] = [];
    if (severe) {
      tips.push('天气不好，建议打车或让家人开车送，别骑车');
    } else if (/雨|雪/.test(weather)) {
      tips.push('路上可能有雨，记得带伞，建议打车');
    } else {
      tips.push('建议打车或让家人接送');
    }
    if (drive.distanceKm >= 15) {
      tips.push('路程较远，最好有人陪同');
    }
    let warning: string = '';
    if (departTs < rt.nowTs) {
      warning = '按建议时间已经来不及了，建议现在就打车出发，或在官方渠道改约时间';
    }

    const plan: TravelPlan = {
      originAddress: rt.currentAddress,
      destAddress: appt.hospitalAddress,
      departTime: DateUtil.formatHm(departTs),
      durationMin: drive.durationMin,
      distanceKm: drive.distanceKm,
      trafficLevel: drive.trafficLevel,
      weather: weather,
      bufferMin: buffer,
      suggestion: tips.join('；'),
      warning: warning
    };

    const departLabel: string = DateUtil.friendlyTime(departTs, rt.nowTs);
    // 就诊日超出预报范围（3 天以外）时网关返回“暂无预报”，播报换成更自然的说法
    const weatherPhrase: string = weather.indexOf('暂无预报') >= 0 ? '就诊那天的天气预报还没出来' : `就诊那天${weather}`;
    let speech: string = `${weatherPhrase}，路上大约${drive.durationMin}分钟，建议${departLabel}出发，` +
      `已经多留了${buffer}分钟。`;
    if (warning.length > 0) {
      speech += warning + '。';
    }
    const data: Record<string, Object> = {
      'travelPlan': plan,
      'departTs': departTs,
      'weatherSource': weatherInfo.source as string,
      'locationSource': rt.locationSource as string
    };
    // 用了演示位置或演示车程时整体标为演示，避免把估算当成实时数据
    const source: DataSourceType = rt.locationSource === DataSourceType.DEMO ? DataSourceType.DEMO : drive.dataSource;
    return this.ok(task.id, speech, JSON.stringify(data), false, source, VerificationStatus.SUGGESTED);
  }
}
