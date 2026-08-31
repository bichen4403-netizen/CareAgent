import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 上传到小艺开放平台的 Skill 必须自包含。
 *
 * 这里不能依赖 entry/src 下的 App 业务文件：开放平台审核时只会拿到
 * SKILL.md 和本脚本，无法解析 App 内的相对 import。App 内的 MedicalAgent
 * 仍然使用 MedicalAssistService；这个文件只负责平台调用适配和演示方案生成。
 */
interface MedicalAssistArgs {
  hospital: string;
  department: string;
  expectedDate: string;
  purpose: string;
  isRevisit: boolean;
}

interface AppointmentData {
  hospitalName: string;
  hospitalAddress: string;
  department: string;
  doctorName: string;
  visitDate: string;
  visitTime: string;
  registrationFee: number;
  queueNo: string;
  buildingName: string;
  floor: string;
  roomNo: string;
  bookingStatus: string;
  officialChannelName: string;
}

interface PreparationData {
  visitItems: string[];
  materials: string[];
  notices: string[];
}

/** 将医疗辅助能力暴露给小艺开放平台。 */
export default class MedicalAssistSkill {
  public async planVisit(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    try {
      const args: MedicalAssistArgs = MedicalAssistSkill.parseArgs(argv);
      if (args.purpose.length === 0) {
        await this.fail(info, 'ERR_INVALID_PARAMS', 'purpose is empty',
          '您这次去医院主要想看病、复查，还是取药呢？');
        return;
      }
      if (args.hospital.length === 0) {
        await this.fail(info, 'ERR_NEED_CLARIFICATION', 'hospital is empty',
          '您想去哪家医院？');
        return;
      }
      if (args.department.length === 0 && MedicalAssistSkill.inferDepartment(args.purpose).length === 0) {
        await this.fail(info, 'ERR_NEED_CLARIFICATION', 'department is empty',
          '您这次是看什么科呢？');
        return;
      }
      if (args.expectedDate.length === 0) {
        await this.fail(info, 'ERR_NEED_CLARIFICATION', 'expectedDate is empty',
          '您计划哪天去医院？');
        return;
      }
      if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(args.expectedDate)) {
        await this.fail(info, 'ERR_INVALID_PARAMS', 'expectedDate format invalid',
          '请提供 YYYY-MM-DD 格式的就诊日期');
        return;
      }

      const appointment: AppointmentData = MedicalAssistSkill.buildAppointment(args);
      const preparation: PreparationData = MedicalAssistSkill.buildPreparation(
        args.purpose, args.isRevisit
      );
      const channel: string = '国家政务服务平台';
      const data: Record<string, Object> = {
        'appointment': appointment,
        'purpose': args.purpose,
        'bookingCompleted': false,
        'officialChannelName': channel,
        'preparation': preparation,
        'speech': MedicalAssistSkill.buildSpeech(appointment, args.purpose, args.isRevisit, channel)
      };
      await this.report(info, {
        code: 0,
        result: {
          'type': 'result',
          'status': 'success',
          'data': data
        }
      });
    } catch (e) {
      const err = e as Error;
      const message: string = err !== null && typeof err.message === 'string' && err.message.length > 0
        ? err.message : 'medical skill unavailable';
      await this.fail(info, 'ERR_INTERNAL', message, '暂时没能生成就诊推荐方案，请稍后再试');
    }
  }

  private static buildAppointment(args: MedicalAssistArgs): AppointmentData {
    const hospital: string = args.hospital;
    const department: string = args.department.length > 0
      ? args.department : MedicalAssistSkill.inferDepartment(args.purpose);
    const date: string = MedicalAssistSkill.normalizeDate(args.expectedDate);
    const isRevisit: boolean = args.isRevisit || MedicalAssistSkill.isFollowUp(args.purpose);
    return {
      hospitalName: hospital,
      hospitalAddress: `${hospital}（人民路128号）`,
      department: department,
      doctorName: '王建国 主任医师',
      visitDate: date,
      visitTime: isRevisit ? '09:00' : '10:30',
      registrationFee: isRevisit ? 15 : 30,
      queueNo: 'A012',
      buildingName: '门诊楼',
      floor: '3楼',
      roomNo: '316诊室',
      bookingStatus: 'RECOMMENDED',
      officialChannelName: '国家政务服务平台'
    };
  }

  private static buildPreparation(purpose: string, isRevisit: boolean): PreparationData {
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

  private static buildSpeech(appointment: AppointmentData, purpose: string,
                             isRevisit: boolean, channel: string): string {
    const followUp: boolean = isRevisit || MedicalAssistSkill.isFollowUp(purpose);
    const dateLabel: string = MedicalAssistSkill.friendlyDate(appointment.visitDate);
    const feeLabel: string = `${appointment.registrationFee}元`;
    if (followUp) {
      return `帮您找到${appointment.hospitalName}${appointment.department}的推荐方案，` +
        `${dateLabel}${appointment.visitTime}，${appointment.doctorName}，挂号费${feeLabel}。` +
        `这只是推荐方案，还需要在${channel}确认才算挂号成功`;
    }
    return `帮您找到${appointment.hospitalName}${appointment.department}${appointment.doctorName}的推荐方案，` +
      `${dateLabel}${appointment.visitTime}，挂号费${feeLabel}，诊室在${appointment.buildingName}` +
      `${appointment.floor}${appointment.roomNo}。还需要在${channel}确认才算挂号成功`;
  }

  private static inferDepartment(purpose: string): string {
    if (purpose.indexOf('高血压') >= 0 || purpose.indexOf('血压') >= 0 || purpose.indexOf('心脏') >= 0) {
      return '心血管内科';
    }
    if (purpose.indexOf('糖尿病') >= 0 || purpose.indexOf('血糖') >= 0) {
      return '内分泌科';
    }
    if (purpose.indexOf('胃镜') >= 0 || purpose.indexOf('肠镜') >= 0 || purpose.indexOf('胃') >= 0) {
      return '消化内科';
    }
    if (purpose.indexOf('眼') >= 0) {
      return '眼科';
    }
    if (purpose.indexOf('骨') >= 0 || purpose.indexOf('腿') >= 0 || purpose.indexOf('膝') >= 0) {
      return '骨科';
    }
    return '';
  }

  private static isFollowUp(purpose: string): boolean {
    return purpose.indexOf('复查') >= 0 || purpose.indexOf('复诊') >= 0 ||
      purpose.indexOf('拿药') >= 0 || purpose.indexOf('取药') >= 0 || purpose.indexOf('续方') >= 0;
  }

  private static normalizeDate(value: string): string {
    if (/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) {
      return value;
    }
    return '';
  }

  private static friendlyDate(value: string): string {
    const timestamp: number = new Date(value).getTime();
    if (isNaN(timestamp)) {
      return value.length > 0 ? value : '待定日期';
    }
    const today: Date = new Date();
    const month: string = `${today.getMonth() + 1}`.padStart(2, '0');
    const day: string = `${today.getDate()}`.padStart(2, '0');
    const todayText: string = `${today.getFullYear()}-${month}-${day}`;
    const start: number = new Date(todayText).getTime();
    const diff: number = Math.round((timestamp - start) / (24 * 3600 * 1000));
    if (diff === 0) {
      return '今天';
    }
    if (diff === 1) {
      return '明天';
    }
    if (diff === 2) {
      return '后天';
    }
    const date: Date = new Date(value);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  private static parseArgs(argv: string[]): MedicalAssistArgs {
    const empty: MedicalAssistArgs = {
      hospital: '', department: '', expectedDate: '', purpose: '', isRevisit: false
    };
    if (argv.length === 0) {
      return empty;
    }
    if (argv.length === 1) {
      const raw: string = typeof argv[0] === 'string' ? argv[0].trim() : '';
      if (raw.length === 0) {
        return empty;
      }
      if (raw.startsWith('{')) {
        try {
          const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
          return {
            hospital: MedicalAssistSkill.readString(parsed, 'hospital', 'arg1'),
            department: MedicalAssistSkill.readString(parsed, 'department', 'arg2'),
            expectedDate: MedicalAssistSkill.readString(parsed, 'expectedDate', 'arg3'),
            purpose: MedicalAssistSkill.readString(parsed, 'purpose', 'arg4'),
            isRevisit: MedicalAssistSkill.readBoolean(parsed, 'isRevisit', 'arg5')
          };
        } catch (e) {
          console.warn(`[MedicalAssistSkill] JSON args parse failed: ${JSON.stringify(e)}`);
        }
      }
      return { hospital: '', department: '', expectedDate: '', purpose: raw, isRevisit: false };
    }
    return {
      hospital: MedicalAssistSkill.clean(argv, 0),
      department: MedicalAssistSkill.clean(argv, 1),
      expectedDate: MedicalAssistSkill.clean(argv, 2),
      purpose: MedicalAssistSkill.clean(argv, 3),
      isRevisit: MedicalAssistSkill.readPositionalBoolean(argv, 4)
    };
  }

  private static clean(argv: string[], index: number): string {
    if (argv.length <= index || typeof argv[index] !== 'string') {
      return '';
    }
    return argv[index].trim();
  }

  private static readPositionalBoolean(argv: string[], index: number): boolean {
    if (argv.length <= index) {
      return false;
    }
    return typeof argv[index] === 'string' && MedicalAssistSkill.toBoolean(argv[index]);
  }

  private static readString(obj: Record<string, Object>, key: string, legacyKey: string): string {
    const value: Object | undefined = obj[key] === undefined ? obj[legacyKey] : obj[key];
    return typeof value === 'string' ? value.trim() : '';
  }

  private static readBoolean(obj: Record<string, Object>, key: string, legacyKey: string): boolean {
    const value: Object | undefined = obj[key] === undefined ? obj[legacyKey] : obj[key];
    if (typeof value === 'boolean') {
      return value;
    }
    return typeof value === 'string' && MedicalAssistSkill.toBoolean(value);
  }

  private static toBoolean(value: string): boolean {
    return value.trim().toLowerCase() === 'true';
  }

  private async fail(info: scriptManager.ArkTSScriptInfo, errCode: string,
                     errMsg: string, suggestion: string): Promise<void> {
    await this.report(info, {
      code: -1,
      result: {
        'type': 'result',
        'status': 'failed',
        'errCode': errCode,
        'errMsg': errMsg,
        'suggestion': suggestion
      }
    });
  }

  private async report(info: scriptManager.ArkTSScriptInfo,
                       result: scriptManager.ExecuteResult): Promise<void> {
    try {
      await scriptManager.completeArkTSScriptInApp(info.context, info.requestCode, result);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[MedicalAssistSkill] report failed: ${err.code}, ${err.message}`);
    }
  }
}
