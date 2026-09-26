/**
 * 医疗辅助服务：App 端医疗 Agent 的业务规则层。
 *
 * 负责：
 *   - 挂号方案推荐（号源为演示数据，接入网关时医院名称/地址/坐标为真实检索结果）
 *   - 就诊前准备清单（事务性整理，不做诊断、不给用药建议）
 *   - 官方渠道确认提示
 * 缺信息或当天约不上时，返回 needClarification + missingSlot，由中枢继续追问。
 */

import {
  Appointment, DataSourceType, IntentType, MedicalPreparation, SlotName, VerificationStatus
} from '../core/AgentTypes';
import { DateUtil } from '../core/DateUtil';
import { MockDataSource } from './MockDataSource';
import { OfficialChannel, OfficialChannelRegistry } from './AppLinkService';
import { HospitalInfo, HospitalService } from './HospitalService';

export interface MedicalAssistRequest {
  intentType: IntentType;
  hospital: string;
  department: string;
  purpose: string;
  expectedDate: string;
  timePreference: string;
  isRevisit: boolean;
  anomalyType: string;
  avoidDoctor: string;
  originLng: number;
  originLat: number;
  cityName: string;
  lastPrescription: string;
}

export interface MedicalAssistResponse {
  success: boolean;
  needClarification: boolean;
  missingSlot: string;
  clarificationQuestion: string;
  appointment: Appointment | null;
  preparation: MedicalPreparation;
  lastPrescription: string;
  speech: string;
  officialChannel: OfficialChannel;
  dataSource: DataSourceType;
  verificationStatus: VerificationStatus;
  errorMsg: string;
}

export class MedicalAssistService {

  static async planVisit(req: MedicalAssistRequest, nowTs: number): Promise<MedicalAssistResponse> {
    if (req.intentType !== IntentType.MEDICAL_VISIT && req.intentType !== IntentType.MEDICINE_REFILL) {
      return MedicalAssistService.clarify('', '目前我能帮您安排看病和取药。您是想去哪家医院看什么科？');
    }
    if (req.hospital.trim().length === 0) {
      return MedicalAssistService.clarify(SlotName.HOSPITAL, '您想去哪家医院？');
    }
    if (req.department.trim().length === 0) {
      return MedicalAssistService.clarify(SlotName.DEPARTMENT, '这次看什么科呢？也可以直接说哪里不舒服。');
    }
    if (!DateUtil.isValidYmd(req.expectedDate)) {
      return MedicalAssistService.clarify(SlotName.DATE, '您想哪天去？可以说“明天”或“下周三上午”。');
    }
    if (DateUtil.isPast(req.expectedDate, nowTs)) {
      return MedicalAssistService.clarify(SlotName.DATE, '那天已经过去了，您想改到哪天？');
    }

    const isRevisit: boolean = req.isRevisit || req.intentType === IntentType.MEDICINE_REFILL;
    const appt: Appointment | null = MockDataSource.queryAppointment(req.hospital.trim(), req.department.trim(),
      req.expectedDate, isRevisit, req.timePreference, nowTs, req.avoidDoctor);
    if (appt === null) {
      const day: string = DateUtil.friendlyDate(req.expectedDate, nowTs);
      return MedicalAssistService.clarify(SlotName.DATE,
        `${day}的门诊已经来不及了（当天挂号要留出路上时间），改到明天还是后天？`);
    }

    // 接入网关时：按当前位置检索真实医院，得到全称、地址与坐标（号源仍为演示数据）
    const info: HospitalInfo | null = await HospitalService.search(appt.hospitalName, req.originLng, req.originLat);
    if (info !== null) {
      appt.hospitalName = info.name;
      appt.hospitalAddress = info.address.length > 0 ? info.address : info.name;
      appt.hospitalLng = info.lng;
      appt.hospitalLat = info.lat;
    }

    const channel: OfficialChannel = OfficialChannelRegistry.resolve(
      `${appt.hospitalName}${appt.hospitalAddress}${info !== null ? info.city : ''}${req.cityName}`);
    appt.officialChannelName = channel.name;

    const preparation: MedicalPreparation =
      MedicalAssistService.buildPreparation(req, appt, isRevisit);
    const day: string = DateUtil.friendlyDate(appt.visitDate, nowTs);
    const feeText: string = appt.registrationFee > 0 ? `，挂号费约${appt.registrationFee}元` : '';
    const changed: string = req.anomalyType === 'DOCTOR_OFF'
      ? '已触发模拟停诊场景，并重新生成演示方案。' : '';
    const speech: string = `这是演示推荐方案，不代表真实号源、医生、诊室或费用。${changed}` +
      `建议${day}${appt.visitTime}去${appt.hospitalName}${appt.department}，` +
      `演示信息为${appt.doctorName}${feeText}。请在${channel.name}确认真实挂号结果。`;

    const resp: MedicalAssistResponse = {
      success: true,
      needClarification: false,
      missingSlot: '',
      clarificationQuestion: '',
      appointment: appt,
      preparation: preparation,
      lastPrescription: req.lastPrescription,
      speech: speech,
      officialChannel: channel,
      dataSource: DataSourceType.DEMO,
      verificationStatus: VerificationStatus.SUGGESTED,
      errorMsg: ''
    };
    return resp;
  }

  private static buildPreparation(req: MedicalAssistRequest, appt: Appointment,
    isRevisit: boolean): MedicalPreparation {
    const visitItems: string[] = [];
    visitItems.push(`${appt.department}${isRevisit ? '复诊' : '就诊'}`);
    if (req.intentType === IntentType.MEDICINE_REFILL) {
      visitItems.push('请医生确认是否继续原来的用药，再开药');
    }
    if (req.anomalyType === 'DOCTOR_OFF') {
      visitItems.push('模拟停诊场景已触发，请在官方渠道查看实际可选医生与时段');
    }

    const materials: string[] = ['身份证', '医保卡（或医保电子凭证）'];
    if (isRevisit) {
      materials.push('上次的病历本或处方单');
      materials.push('正在吃的药或药盒');
    }
    if (appt.department.indexOf('心血管') >= 0) {
      materials.push('最近几天的血压记录（有就带上）');
    } else if (appt.department.indexOf('内分泌') >= 0) {
      materials.push('最近的血糖记录（有就带上）');
    } else if (appt.department.indexOf('眼科') >= 0) {
      materials.push('平时戴的眼镜');
    }

    const notices: string[] = [
      `先在官方渠道确认挂号，以医院最终安排为准`,
      '如需空腹抽血等检查，请以医院通知为准',
      '就诊时把最近的不舒服和正在吃的药如实告诉医生'
    ];
    if (req.lastPrescription.length > 0) {
      notices.push(`上次处方：${req.lastPrescription}（仅供提醒医生参考，是否调整听医生的）`);
    }
    const prep: MedicalPreparation = { visitItems: visitItems, materials: materials, notices: notices };
    return prep;
  }

  private static clarify(slot: string, question: string): MedicalAssistResponse {
    const channel: OfficialChannel = OfficialChannelRegistry.resolve('');
    const resp: MedicalAssistResponse = {
      success: false,
      needClarification: true,
      missingSlot: slot,
      clarificationQuestion: question,
      appointment: null,
      preparation: { visitItems: [], materials: [], notices: [] },
      lastPrescription: '',
      speech: question,
      officialChannel: channel,
      dataSource: DataSourceType.LOCAL_COMPUTED,
      verificationStatus: VerificationStatus.UNVERIFIED,
      errorMsg: `NEED_CLARIFICATION:${slot}`
    };
    return resp;
  }
}
