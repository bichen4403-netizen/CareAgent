import { BookingStatus } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
import type { Appointment, TravelPlan, IndoorNavPlan, NavStep } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
export class MockDataSource {
    /** 查询号源与排班 */
    static async queryAppointment(hospital: string, department: string, expectedDate: string, isRevisit: boolean): Promise<Appointment> {
        await MockDataSource.delay(500);
        const hospitalName: string = hospital.length > 0 ? hospital : '市第一人民医院';
        const dept: string = department.length > 0 ? department : '心血管内科';
        let date: string = expectedDate;
        if (date.length === 0) {
            const d: Date = new Date(Date.now() + 24 * 3600 * 1000);
            const m: string = `${d.getMonth() + 1}`.padStart(2, '0');
            const day: string = `${d.getDate()}`.padStart(2, '0');
            date = `${d.getFullYear()}-${m}-${day}`;
        }
        // 复诊优先安排上午早时段，减少老人等待
        const visitTime: string = isRevisit ? '09:00' : '10:30';
        return {
            hospitalName: hospitalName,
            hospitalAddress: `${hospitalName}（人民路128号）`,
            department: dept,
            doctorName: '王建国 主任医师',
            visitDate: date,
            visitTime: visitTime,
            registrationFee: isRevisit ? 15 : 30,
            queueNo: 'A012',
            buildingName: '门诊楼',
            floor: '3楼',
            roomNo: '316诊室',
            bookingStatus: BookingStatus.RECOMMENDED,
            officialChannelName: '' // 具体值由 MedicalAgent 统一覆盖
        };
    }
    /** 查询出行方案（含路况与天气影响） */
    static async queryTravel(origin: string, dest: string, arriveBy: string, weather: string): Promise<TravelPlan> {
        await MockDataSource.delay(400);
        const baseDuration: number = 28;
        let traffic: string = '缓行';
        let buffer: number = 10;
        if (weather.indexOf('雨') >= 0 || weather.indexOf('雪') >= 0) {
            traffic = '拥堵';
            buffer = 25;
        }
        const totalMin: number = baseDuration + buffer;
        // 额外再留 15 分钟用于取号排队
        const departTime: string = MockDataSource.minusMinutes(arriveBy, totalMin + 15);
        let suggestion: string = '路况正常，按时出发即可';
        if (buffer >= 25) {
            suggestion = '今天有雨，建议提前出发，已为您多留出时间';
        }
        else if (traffic === '缓行') {
            suggestion = '路上略有缓行，已预留缓冲时间';
        }
        return {
            originAddress: origin.length > 0 ? origin : '当前位置',
            destAddress: dest,
            departTime: departTime,
            durationMin: baseDuration,
            distanceKm: 8.6,
            trafficLevel: traffic,
            weather: weather,
            bufferMin: buffer,
            suggestion: suggestion
        };
    }
    /** 查询院内路线 */
    static async queryIndoorNav(hospital: string, building: string, floor: string, room: string): Promise<IndoorNavPlan> {
        await MockDataSource.delay(300);
        const steps: NavStep[] = [
            { order: 1, instruction: '从门诊楼正门进入，前方10米右手边是自助机', landmark: '门诊大厅' },
            { order: 2, instruction: '在自助机取号，或直接到人工窗口报手机号取号', landmark: '取号区' },
            { order: 3, instruction: `乘坐正对面的2号电梯上到${floor}`, landmark: '2号电梯' },
            { order: 4, instruction: `出电梯后向左走，第三个房间即为${room}`, landmark: room }
        ];
        return {
            entrance: `${building}正门`,
            targetRoom: `${floor}${room}`,
            steps: steps,
            estimatedWalkMin: 6
        };
    }
    /** 取药路线（取药场景替代诊室导航） */
    static async queryPharmacyNav(hospital: string): Promise<IndoorNavPlan> {
        await MockDataSource.delay(300);
        const steps: NavStep[] = [
            { order: 1, instruction: '从门诊楼正门进入，向右前方走约20米', landmark: '门诊大厅' },
            { order: 2, instruction: '在缴费窗口完成缴费，或用手机扫码支付', landmark: '缴费窗口' },
            { order: 3, instruction: '缴费窗口旁边就是药房，凭单据取药', landmark: '门诊药房' }
        ];
        return {
            entrance: '门诊楼正门',
            targetRoom: '1楼门诊药房',
            steps: steps,
            estimatedWalkMin: 4
        };
    }
    /** 天气查询 */
    static async queryWeather(lat: number, lng: number): Promise<string> {
        await MockDataSource.delay(200);
        return '小雨';
    }
    // ==================== 工具方法 ====================
    private static delay(ms: number): Promise<void> {
        return new Promise<void>((resolve: () => void) => {
            setTimeout(resolve, ms);
        });
    }
    /** HH:mm 减去若干分钟 */
    static minusMinutes(hhmm: string, minutes: number): string {
        const parts: string[] = hhmm.split(':');
        if (parts.length !== 2) {
            return hhmm;
        }
        let total: number = parseInt(parts[0]) * 60 + parseInt(parts[1]) - minutes;
        if (total < 0) {
            total += 24 * 60;
        }
        const h: string = `${Math.floor(total / 60)}`.padStart(2, '0');
        const m: string = `${total % 60}`.padStart(2, '0');
        return `${h}:${m}`;
    }
    /** YYYY-MM-DD + HH:mm 转时间戳 */
    static toTimestamp(date: string, time: string): number {
        return new Date(`${date}T${time}:00`).getTime();
    }
}
