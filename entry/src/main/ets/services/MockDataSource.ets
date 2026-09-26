/**
 * 智护同行 - 演示数据源
 *
 * 医院号源、诊室楼层等没有公开接口的数据，在初赛阶段用演示数据代替，
 * 所有结果都标注 dataSource = DEMO，页面上会显示“演示数据”标签。
 * 演示数据仅用于完整流程演示，不是医院号源或院内地图：医生、时段、费用、诊室、
 * 排队号和路线均为合成数据，用户必须以医院官方渠道和现场导视为准。
 */

import { Appointment, IndoorNavPlan, NavStep, BookingStatus } from '../core/AgentTypes';
import { DateUtil } from '../core/DateUtil';

interface DeptDemo {
  dept: string;
  doctor: string;
  title: string;
  building: string;
  floor: string;
  room: string;
}

const DEPT_DEMO: DeptDemo[] = [
  { dept: '心血管内科', doctor: '演示心内科医生', title: '模拟号源', building: '演示门诊楼', floor: '演示3楼', room: '演示316诊室' },
  { dept: '内分泌科', doctor: '演示内分泌医生', title: '模拟号源', building: '演示门诊楼', floor: '演示4楼', room: '演示408诊室' },
  { dept: '消化内科', doctor: '演示消化内科医生', title: '模拟号源', building: '演示门诊楼', floor: '演示3楼', room: '演示305诊室' },
  { dept: '呼吸内科', doctor: '演示呼吸内科医生', title: '模拟号源', building: '演示门诊楼', floor: '演示2楼', room: '演示221诊室' },
  { dept: '神经内科', doctor: '演示神经内科医生', title: '模拟号源', building: '演示门诊楼', floor: '演示5楼', room: '演示502诊室' },
  { dept: '骨科', doctor: '演示骨科医生', title: '模拟号源', building: '演示外科楼', floor: '演示1楼', room: '演示108诊室' },
  { dept: '眼科', doctor: '演示眼科医生', title: '模拟号源', building: '演示门诊楼', floor: '演示2楼', room: '演示212诊室' },
  { dept: '耳鼻喉科', doctor: '演示耳鼻喉科医生', title: '模拟号源', building: '演示门诊楼', floor: '演示2楼', room: '演示208诊室' },
  { dept: '口腔科', doctor: '演示口腔科医生', title: '模拟号源', building: '演示门诊楼', floor: '演示1楼', room: '演示112诊室' },
  { dept: '体检中心', doctor: '演示体检医生', title: '模拟号源', building: '演示体检中心', floor: '演示1楼', room: '演示体检大厅' }
];

const DEFAULT_DEMO: DeptDemo = {
  dept: '', doctor: '演示医生', title: '模拟号源', building: '演示门诊楼', floor: '演示2楼', room: '演示201诊室'
};

/** 可预约时段：上午两个、下午两个 */
const MORNING_SLOTS: string[] = ['09:00', '10:30'];
const AFTERNOON_SLOTS: string[] = ['14:30', '15:30'];

/** 当天挂号至少提前 90 分钟，留出路上时间 */
const SAME_DAY_LEAD_MIN: number = 90;

export class MockDataSource {

  private static findDept(department: string): DeptDemo {
    for (let i = 0; i < DEPT_DEMO.length; i++) {
      if (department.indexOf(DEPT_DEMO[i].dept) >= 0 || DEPT_DEMO[i].dept.indexOf(department) >= 0) {
        if (department.length > 0) {
          return DEPT_DEMO[i];
        }
      }
    }
    return DEFAULT_DEMO;
  }

  private static feeOf(title: string): number {
    if (title === '主任医师') {
      return 50;
    }
    if (title === '副主任医师') {
      return 35;
    }
    return title.length > 0 ? 20 : 0;
  }

  /** 按日期和科室生成稳定的排队号，同一天同科室多次规划结果一致 */
  private static queueNoOf(date: string, dept: string, time: string): string {
    let hash: number = 0;
    const key: string = `${date}${dept}${time}`;
    for (let i = 0; i < key.length; i++) {
      hash = (hash * 31 + key.charCodeAt(i)) % 997;
    }
    const n: number = 5 + hash % 40;
    return `A${n < 10 ? '00' : '0'}${n}`;
  }

  /** 按偏好挑选时段；当天则跳过已经来不及的时段，全部来不及返回空串 */
  private static pickTime(date: string, preference: string, isRevisit: boolean, nowTs: number,
    avoidTime: string): string {
    let candidates: string[] = [];
    if (preference === '下午') {
      candidates = AFTERNOON_SLOTS.concat(MORNING_SLOTS);
    } else if (preference === '上午') {
      candidates = MORNING_SLOTS.concat(AFTERNOON_SLOTS);
    } else {
      candidates = isRevisit ? ['09:00', '10:30', '14:30', '15:30'] : ['10:30', '09:00', '14:30', '15:30'];
    }
    const isToday: boolean = date === DateUtil.todayStr(nowTs);
    for (let i = 0; i < candidates.length; i++) {
      const t: string = candidates[i];
      if (t === avoidTime) {
        continue;
      }
      if (isToday) {
        const ts: number = DateUtil.toTimestamp(date, t);
        if (isNaN(ts) || ts - nowTs < SAME_DAY_LEAD_MIN * 60 * 1000) {
          continue;
        }
      }
      return t;
    }
    return '';
  }

  /**
   * 查询挂号方案。返回 null 表示该日期已约不上（当天门诊时间已过）。
   * avoidDoctor 用于“医生停诊”重规划：换同科室另一位医生、换一个时段。
   */
  static queryAppointment(hospital: string, department: string, date: string, isRevisit: boolean,
    timePreference: string, nowTs: number, avoidDoctor: string): Appointment | null {
    const demo: DeptDemo = MockDataSource.findDept(department);
    let doctor: string = demo.doctor;
    let title: string = demo.title;
    let avoidTime: string = '';
    if (avoidDoctor.length > 0 && avoidDoctor.indexOf(demo.doctor) >= 0) {
      doctor = '演示备用医生';
      title = '模拟号源';
      avoidTime = MockDataSource.pickTime(date, timePreference, isRevisit, nowTs, '');
    }
    const time: string = MockDataSource.pickTime(date, timePreference, isRevisit, nowTs, avoidTime);
    if (time.length === 0) {
      return null;
    }
    const dept: string = department.length > 0 ? department : '普通内科';
    const appt: Appointment = {
      hospitalName: hospital,
      hospitalAddress: `${hospital}（演示地址，非真实位置）`,
      hospitalLng: 0,
      hospitalLat: 0,
      department: dept,
      doctorName: title.length > 0 ? `${doctor} ${title}` : doctor,
      visitDate: date,
      visitTime: time,
      registrationFee: MockDataSource.feeOf(title),
      queueNo: `演示${MockDataSource.queueNoOf(date, dept, time)}`,
      buildingName: demo.building,
      floor: demo.floor,
      roomNo: demo.room,
      bookingStatus: BookingStatus.RECOMMENDED,
      officialChannelName: ''
    };
    return appt;
  }

  /** 院内导航：仅生成现场核对模板，不假设任一医院的实际布局。 */
  static queryIndoorNav(buildingName: string, floor: string, roomNo: string): IndoorNavPlan {
    const steps: NavStep[] = [];
    steps.push({ order: 1, instruction: `进入${buildingName}后，先向导诊台核对${floor}${roomNo}是否正确`, landmark: '导诊台或服务台' });
    steps.push({ order: 2, instruction: `按现场导视牌前往${floor}，行动不便时询问无障碍路线`, landmark: '楼层与科室导视牌' });
    steps.push({ order: 3, instruction: `到${floor}后，按门牌和叫号屏确认${roomNo}，再到候诊区等候`, landmark: '门牌、叫号屏或导诊人员' });
    const plan: IndoorNavPlan = {
      entrance: `${buildingName}入口（请以现场导视为准）`,
      targetRoom: `${buildingName}${floor}${roomNo}（演示模板，待现场确认）`,
      steps: steps,
      estimatedWalkMin: 0
    };
    return plan;
  }

  /** 取药导航：仅提示到现场核对，不假设缴费处或药房位置。 */
  static queryPharmacyNav(): IndoorNavPlan {
    const steps: NavStep[] = [
      { order: 1, instruction: '先向导诊台确认缴费处和药房的位置', landmark: '导诊台或服务台' },
      { order: 2, instruction: '按医院现场导视前往缴费处或药房', landmark: '缴费、药房导视牌' },
      { order: 3, instruction: '取药后在窗口前核对药名和数量，有疑问立即询问工作人员', landmark: '药房窗口' }
    ];
    const plan: IndoorNavPlan = {
      entrance: '医院入口（请以现场导视为准）',
      targetRoom: '药房（演示模板，待导诊台确认）',
      steps: steps,
      estimatedWalkMin: 0
    };
    return plan;
  }
}
