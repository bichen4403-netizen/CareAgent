/**
 * 医疗辅助领域服务。
 *
 * 负责就诊信息补全、推荐方案生成、官方渠道解析与用户播报文案。
 * App 内 MedicalAgent 与系统 MedicalAssistSkill 共同调用本服务，避免形成两套业务逻辑。
 * 当前号源仍来自 MockDataSource；替换真实医院接口时只需修改本服务依赖的数据源。
 */

import { Appointment, BookingStatus, ServiceRecord } from '../core/AgentTypes';
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
}

export class MedicalAssistService {
  static async planVisit(request: MedicalAssistRequest,
                         anomalyType: string = 'NONE'): Promise<MedicalAssistResponse> {
    const store: ContextStore = ContextStore.getInstance();
    let hospital: string = request.hospital.trim();
    let department: string = request.department.trim();
    let isRevisit: boolean = request.isRevisit;

    const last: ServiceRecord | null = store.findLastVisit(hospital, department);
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
    if (department.length === 0) {
      department = MedicalAssistService.inferDepartment(request.purpose);
    }

    if (hospital.length === 0) {
      return MedicalAssistService.clarification('您想去哪家医院？', last, isRevisit);
    }
    if (department.length === 0) {
      return MedicalAssistService.clarification('您这次是看什么科呢？', last, isRevisit);
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
        appointment, request.purpose, isRevisit, replanned, channel
      ),
      lastPrescription: last === null ? '' : last.prescription,
      isRevisit: isRevisit,
      replanned: replanned
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
      replanned: false
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
