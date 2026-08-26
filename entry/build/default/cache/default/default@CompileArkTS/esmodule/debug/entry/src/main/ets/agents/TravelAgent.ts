import type { AgentResult, TaskNode, RuntimeContext, ParsedIntent, Appointment, TravelPlan } from '../core/AgentTypes';
import { BaseAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/BaseAgent";
import { blackboard } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/EventBus";
import { ContextStore } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/ContextStore";
import { TravelService } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/TravelService";
import type { DrivingResult } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/TravelService";
import { MockDataSource } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/MockDataSource";
export class TravelAgent extends BaseAgent {
    readonly name: string = 'TravelAgent';
    protected async run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
        const intent: ParsedIntent = JSON.parse(task.payload) as ParsedIntent;
        // 从黑板读取医疗 Agent 的产出
        const medicalResult = blackboard.getResultByAgent('MedicalAgent');
        if (medicalResult === undefined) {
            return this.fail(task.id, '还没确定就诊时间，稍后再为您安排出行', 'medical result missing');
        }
        const medicalData: Record<string, Object> = JSON.parse(medicalResult.data) as Record<string, Object>;
        const appt: Appointment = medicalData['appointment'] as Appointment;
        const profile = ContextStore.getInstance().getProfile();
        const origin: string = rt.currentAddress.length > 0 ? rt.currentAddress : profile.homeAddress;
        // 车程/距离/路况改为真实查询（未配置高德 Key 时自动降级为 Mock 数值）
        const driving: DrivingResult = await TravelService.getDrivingByAddress(rt.currentLng, rt.currentLat, appt.hospitalAddress);
        // 出发时间倒推逻辑保留在这里：就诊时间 - 车程 - 天气/路况缓冲 - 15分钟取号
        const plan: TravelPlan = TravelAgent.buildTravelPlan(origin, appt, driving, rt.weather);
        const speech: string = TravelAgent.buildSpeech(plan, appt);
        const dataObj: Record<string, Object> = {
            'travelPlan': plan,
            'arriveBy': appt.visitTime,
            'visitDate': appt.visitDate
        };
        // 叫车会产生实际费用，需用户确认
        return this.ok(task.id, speech, JSON.stringify(dataObj), true);
    }
    /**
     * 整合真实车程数据 + 天气/路况缓冲，倒推出发时间
     * 缓冲逻辑与之前 Mock 版本保持一致：有雨雪或拥堵时多留 25 分钟，否则 10 分钟
     */
    private static buildTravelPlan(origin: string, appt: Appointment, driving: DrivingResult, weather: string): TravelPlan {
        let buffer: number = 10;
        if (weather.indexOf('雨') >= 0 || weather.indexOf('雪') >= 0 || driving.trafficLevel === '拥堵') {
            buffer = 25;
        }
        const totalMin: number = driving.durationMin + buffer;
        // 再留 15 分钟用于取号排队
        const departTime: string = MockDataSource.minusMinutes(appt.visitTime, totalMin + 15);
        let suggestion: string = '路况正常，按时出发即可';
        if (buffer >= 25 && (weather.indexOf('雨') >= 0 || weather.indexOf('雪') >= 0)) {
            suggestion = `今天有${weather}，建议提前出发，已为您多留出时间`;
        }
        else if (driving.trafficLevel !== '畅通') {
            suggestion = `路上${driving.trafficLevel}，已预留缓冲时间`;
        }
        return {
            originAddress: origin,
            destAddress: appt.hospitalAddress,
            departTime: departTime,
            durationMin: driving.durationMin,
            distanceKm: driving.distanceKm,
            trafficLevel: driving.trafficLevel,
            weather: weather,
            bufferMin: buffer,
            suggestion: suggestion
        };
    }
    private static buildSpeech(p: TravelPlan, a: Appointment): string {
        let s: string = `建议您${p.departTime}出发，车程大约${p.durationMin}分钟`;
        if (p.bufferMin >= 25) {
            s += `。${p.suggestion}`;
        }
        else if (p.trafficLevel !== '畅通') {
            s += `，当前路况${p.trafficLevel}，已多留出${p.bufferMin}分钟`;
        }
        s += `，到了${a.visitTime}正好赶上看诊`;
        return s;
    }
}
