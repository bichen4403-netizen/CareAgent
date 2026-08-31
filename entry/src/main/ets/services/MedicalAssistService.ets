/**
 * 医疗辅助领域服务。
 *
 * 负责就诊信息补全、推荐方案生成、官方渠道解析与用户播报文案。
 * App 内 MedicalAgent 与系统 MedicalAssistSkill 共同调用本服务，避免形成两套业务逻辑。
 * 当前号源仍来自 MockDataSource；替换真实医院接口时只需修改本服务依赖的数据源。
 */

import { Appointment, BookingStatus, ServiceRecord, MedicalPreparation } from '../core/AgentTypes';
import { ContextStore } from '../core/ContextStore';
import { MockDataSource } from './MockDataSource';
import { OfficialChannel, OfficialChannelRegistry } from './AppLinkService';

export interface MedicalAssistRequest {
  hospital: string;
  department: string;
  expectedDate: string;
  purpose: string;
  isRevisit: boolean;
}

export interface MedicalAssistResponse {
  success: boolean;
  appointment: Appointment | null;
  officialChannel: OfficialChannel | null;
  needClarification: boolean;
  clarifyQuestion: string;
  speech: string;
  lastPrescription: string;
  isRevisit: boolean;
  replanned: boolean;
  preparation: MedicalPreparation;
}

export class MedicalAssistService {
  static async planVisit(request: MedicalAssistRequest,
                         anomalyType: string = 'NONE'): Promise<MedicalAssistResponse> {
    const store: ContextStore = ContextStore.getInstance();
    let hospital: string = request.hospital.trim();
    let department: string = request.department.trim();
    const purpose: string = request.purpose.trim();
    let isRevisit: boolean = request.isRevisit;

    if (purpose.length === 0) {
      return MedicalAssistService.clarification(
        '您这次去医院主要是看病、复查，还是取药呢？', null, isRevisit
      );
    }

    // 只有复诊/续方场景允许使用端侧历史补全科室和医生。
    // 首次就诊或新的检查项目不能沿用上次科室，避免把“胃镜”误安排到
    // 上次的心血管内科。
    const allowHistory: boolean = isRevisit || MedicalAssistService.isFollowUpPurpose(purpose);

    // 先按用户给出的槽位查历史；常去医院补全后再查一次，
    // 否则“我要拿药”这种请求会错过已有的复诊记录。
    let last: ServiceRecord | null = allowHistory
      ? store.findLastVisit(hospital, department) : null;
    if (last !== null) {
      if (hospital.length === 0) {
        hospital = last.hospital;
      }
      if (department.length === 0) {
        department = last.department;
      }
      if (last.followUpDays > 0) {
        isRevisit = true;
      }
    }

    if (hospital.length === 0) {
      const preferred: string[] = store.getProfile().preferredHospitals;
      if (preferred.length > 0) {
        hospital = preferred[0];
      }
    }

    if (allowHistory && last === null && hospital.length > 0) {
      last = store.findLastVisit(hospital, department);
      if (last !== null && department.length === 0) {
        department = last.department;
      }
    }

    if (department.length === 0) {
      department = MedicalAssistService.inferDepartment(purpose);
    }

    // 科室由目的推断出来后，再尝试一次精确历史匹配。
    if (allowHistory && last === null && hospital.length > 0 && department.length > 0) {
      last = store.findLastVisit(hospital, department);
      if (last !== null && last.followUpDays > 0) {
        isRevisit = true;
      }
    }

    if (hospital.length === 0) {
      return MedicalAssistService.clarification('您想去哪家医院？', last, isRevisit);
    }
    if (department.length === 0) {
      return MedicalAssistService.clarification('您这次是看什么科呢？', last, isRevisit);
    }
    if (request.expectedDate.trim().length === 0) {
      return MedicalAssistService.clarification('您计划哪天去医院？', last, isRevisit);
    }

    const appointment: Appointment = await MockDataSource.queryAppointment(
      hospital, department, request.expectedDate.trim(), isRevisit
    );
    const replanned: boolean = anomalyType === 'DOCTOR_OFF';
    if (replanned) {
      appointment.doctorName = '李慧敏 副主任医师';
      appointment.visitTime = '14:30';
      appointment.roomNo = '318诊室';
    }

    const channel: OfficialChannel = OfficialChannelRegistry.resolve(appointment.hospitalAddress);
    appointment.bookingStatus = BookingStatus.RECOMMENDED;
    appointment.officialChannelName = channel.name;

    return {
      success: true,
      appointment: appointment,
      officialChannel: channel,
      needClarification: false,
      clarifyQuestion: '',
      speech: MedicalAssistService.buildSpeech(
        appointment, purpose, isRevisit, replanned, channel
      ),
      lastPrescription: last === null ? '' : last.prescription,
      isRevisit: isRevisit,
      replanned: replanned,
      preparation: MedicalAssistService.buildPreparation(purpose, isRevisit)
    };
  }

  private static clarification(question: string, last: ServiceRecord | null,
                               isRevisit: boolean): MedicalAssistResponse {
    return {
      success: false,
      appointment: null,
      officialChannel: null,
      needClarification: true,
      clarifyQuestion: question,
      speech: '',
      lastPrescription: last === null ? '' : last.prescription,
      isRevisit: isRevisit,
      replanned: false,
      preparation: { visitItems: [], materials: [], notices: [] }
    };
  }

  private static inferDepartment(purpose: string): string {
    if (purpose.indexOf('高血压') >= 0 || purpose.indexOf('血压') >= 0 ||
        purpose.indexOf('心脏') >= 0) {
      return '心血管内科';
    }
    if (purpose.indexOf('糖尿病') >= 0 || purpose.indexOf('血糖') >= 0) {
      return '内分泌科';
    }
    if (purpose.indexOf('骨') >= 0 || purpose.indexOf('腿') >= 0 || purpose.indexOf('膝') >= 0) {
      return '骨科';
    }
    if (purpose.indexOf('眼') >= 0) {
      return '眼科';
    }
    return '';
  }

  private static isFollowUpPurpose(purpose: string): boolean {
    return purpose.indexOf('复查') >= 0 || purpose.indexOf('复诊') >= 0 ||
      purpose.indexOf('拿药') >= 0 || purpose.indexOf('取药') >= 0 ||
      purpose.indexOf('续方') >= 0;
  }

  /** 事务性准备清单：不推断病情、不新增药物，只整理用户到院前要做的事。 */
  private static buildPreparation(purpose: string, isRevisit: boolean): MedicalPreparation {
    const visitItems: string[] = [
      '确认预约医院、科室和时间',
      '建议提前30分钟到院，预留取号和找路时间'
    ];
    const materials: string[] = [
      '身份证',
      '医保卡（如使用）',
      '既往检查报告或病历资料',
      '预约凭证或手机截图'
    ];
    const notices: string[] = [
      '以医院官方通知和医生要求为准',
      '不确定事项请提前咨询医院导医或医生'
    ];

    if (purpose.indexOf('胃镜') >= 0 || purpose.indexOf('肠镜') >= 0) {
      notices.unshift('如预约单有禁食、清肠等要求，请严格按医院通知准备');
    } else if (purpose.indexOf('药') >= 0 || isRevisit) {
      materials.push('正在使用的药品或上次处方信息');
      notices.unshift('只按原医嘱用药，不自行加减量或停药');
    } else {
      notices.unshift('把近期症状、检查单和想咨询的问题记在手机里');
    }

    return { visitItems: visitItems, materials: materials, notices: notices };
  }

  private static buildSpeech(appointment: Appointment, purpose: string, isRevisit: boolean,
                             replanned: boolean, channel: OfficialChannel): string {
    const dateLabel: string = MedicalAssistService.friendlyDate(appointment.visitDate);
    if (replanned) {
      return `原来的${appointment.department}医生今天停诊了，我帮您重新看了一下，` +
        `改约${appointment.doctorName}，${dateLabel}${appointment.visitTime}，` +
        `诊室换到${appointment.roomNo}，还需要在${channel.name}确认改约`;
    }

    const refill: boolean = purpose.indexOf('药') >= 0 || purpose.indexOf('续方') >= 0;
    if (refill || isRevisit) {
      return `帮您找到了${appointment.hospitalName}${appointment.department}的号，` +
        `${dateLabel}${appointment.visitTime}，${appointment.doctorName}，` +
        `挂号费${appointment.registrationFee}元。这只是推荐方案，` +
        `还需要在${channel.name}确认才算挂号成功`;
    }
    return `帮您找到了${appointment.hospitalName}${appointment.department}` +
      `${appointment.doctorName}的号，${dateLabel}${appointment.visitTime}，` +
      `挂号费${appointment.registrationFee}元，诊室在${appointment.buildingName}` +
      `${appointment.floor}${appointment.roomNo}。还需要在${channel.name}确认才算挂号成功`;
  }

  private static friendlyDate(dateStr: string): string {
    const target: number = new Date(dateStr).getTime();
    if (isNaN(target)) {
      return dateStr.length > 0 ? dateStr : '待定日期';
    }
    const today: Date = new Date();
    const todayStr: string = `${today.getFullYear()}-` +
      `${`${today.getMonth() + 1}`.padStart(2, '0')}-${`${today.getDate()}`.padStart(2, '0')}`;
    const todayStart: number = new Date(todayStr).getTime();
    const diffDays: number = Math.round((target - todayStart) / (24 * 3600 * 1000));
    if (diffDays === 0) {
      return '今天';
    }
    if (diffDays === 1) {
      return '明天';
    }
    if (diffDays === 2) {
      return '后天';
    }
    const date: Date = new Date(dateStr);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }
}
