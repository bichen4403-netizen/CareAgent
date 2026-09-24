/**
 * 智护同行 - 演示数据源
 *
 * 医院号源、诊室楼层等没有公开接口的数据，在初赛阶段用演示数据代替，
 * 所有结果都标注 dataSource = DEMO，页面上会显示“演示数据”标签。
 * 演示数据尽量贴近真实：不同科室对应不同医生/楼层；上午/下午偏好生效；
 * 当天门诊时间已过会如实返回“今天约不上”。
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
  { dept: '心血管内科', doctor: '王建国', title: '主任医师', building: '门诊楼', floor: '3楼', room: '316诊室' },
  { dept: '内分泌科', doctor: '刘敏', title: '副主任医师', building: '门诊楼', floor: '4楼', room: '408诊室' },
  { dept: '消化内科', doctor: '孙立', title: '主任医师', building: '门诊楼', floor: '3楼', room: '305诊室' },
  { dept: '呼吸内科', doctor: '周红', title: '副主任医师', building: '门诊楼', floor: '2楼', room: '221诊室' },
  { dept: '神经内科', doctor: '吴涛', title: '主任医师', building: '门诊楼', floor: '5楼', room: '502诊室' },
  { dept: '骨科', doctor: '赵刚', title: '副主任医师', building: '外科楼', floor: '1楼', room: '108诊室' },
  { dept: '眼科', doctor: '陈静', title: '主治医师', building: '门诊楼', floor: '2楼', room: '212诊室' },
  { dept: '耳鼻喉科', doctor: '郑华', title: '主治医师', building: '门诊楼', floor: '2楼', room: '208诊室' },
  { dept: '口腔科', doctor: '何平', title: '主治医师', building: '门诊楼', floor: '1楼', room: '112诊室' },
  { dept: '体检中心', doctor: '体检医生', title: '', building: '体检中心', floor: '1楼', room: '体检大厅' }
];

const DEFAULT_DEMO: DeptDemo = {
  dept: '', doctor: '张华', title: '主治医师', building: '门诊楼', floor: '2楼', room: '201诊室'
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
      doctor = '李明';
      title = '副主任医师';
      avoidTime = MockDataSource.pickTime(date, timePreference, isRevisit, nowTs, '');
    }
    const time: string = MockDataSource.pickTime(date, timePreference, isRevisit, nowTs, avoidTime);
    if (time.length === 0) {
      return null;
    }
    const dept: string = department.length > 0 ? department : '普通内科';
    const appt: Appointment = {
      hospitalName: hospital,
      hospitalAddress: `${hospital}（演示地址：人民路128号）`,
      hospitalLng: 0,
      hospitalLat: 0,
      department: dept,
      doctorName: title.length > 0 ? `${doctor} ${title}` : doctor,
      visitDate: date,
      visitTime: time,
      registrationFee: MockDataSource.feeOf(title),
      queueNo: MockDataSource.queueNoOf(date, dept, time),
      buildingName: demo.building,
      floor: demo.floor,
      roomNo: demo.room,
      bookingStatus: BookingStatus.RECOMMENDED,
      officialChannelName: ''
    };
    return appt;
  }

  /** 院内导航：楼层不同步骤不同（1 楼不需要坐电梯） */
  static queryIndoorNav(buildingName: string, floor: string, roomNo: string): IndoorNavPlan {
    const steps: NavStep[] = [];
    steps.push({ order: 1, instruction: `从医院正门进入${buildingName}，先到一楼大厅`, landmark: '门口有导诊台，可以找工作人员帮忙' });
    steps.push({ order: 2, instruction: '在自助机上刷医保卡或身份证取号，取号后拿好小票', landmark: '大厅左手边的自助机' });
    if (floor !== '1楼' && floor.length > 0) {
      steps.push({ order: 3, instruction: `坐电梯上${floor}，出电梯后看墙上的科室指示牌`, landmark: '电梯在大厅正中间，腿脚不便别走楼梯' });
    } else {
      steps.push({ order: 3, instruction: '就在一楼，顺着地上的指示线往里走', landmark: '跟着地面彩色导引线走' });
    }
    steps.push({ order: steps.length + 1, instruction: `找到${roomNo}门口，在候诊区坐下等叫号`, landmark: '门口屏幕会显示排队号' });
    const plan: IndoorNavPlan = {
      entrance: '医院正门',
      targetRoom: `${buildingName}${floor}${roomNo}`,
      steps: steps,
      estimatedWalkMin: floor === '1楼' ? 5 : 8
    };
    return plan;
  }

  /** 取药导航（续方场景） */
  static queryPharmacyNav(): IndoorNavPlan {
    const steps: NavStep[] = [
      { order: 1, instruction: '看完医生后，先到一楼缴费窗口或自助机缴费', landmark: '门诊大厅右手边' },
      { order: 2, instruction: '缴费后到一楼西药房取药，把缴费单交给窗口', landmark: '药房门口有叫号屏' },
      { order: 3, instruction: '拿到药先在窗口前核对药名和数量，再离开', landmark: '有疑问直接问药房工作人员' }
    ];
    const plan: IndoorNavPlan = {
      entrance: '门诊大厅',
      targetRoom: '一楼西药房',
      steps: steps,
      estimatedWalkMin: 5
    };
    return plan;
  }
}
