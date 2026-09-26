/**
 * 智护同行 - 确定性语言规则
 *
 * 大模型负责“理解整句话”，但下面这些事情必须由代码确定性地完成：
 *   - 医院名抽取（“帮我挂协和医院的号”不能抽成“帮我挂协和医院”）
 *   - 科室推断（关键词表 + 显式“XX科”）
 *   - 紧急情况 / 取消 / 联系家人 / 查询已有安排 的识别
 *   - 离线时从处方单文字里抽取结构化字段
 * 离线规则模型（MockLLMProvider）、意图解析、医疗服务共用这一份规则，保证行为一致。
 * 本文件不依赖系统 Kit，可在 Node 环境下单测。
 */

import { IntentType } from './AgentTypes';
import { DateUtil } from './DateUtil';

interface DeptRule {
  dept: string;
  keywords: string[];
}

const DEPT_RULES: DeptRule[] = [
  { dept: '心血管内科', keywords: ['高血压', '血压', '心脏', '心慌', '心悸', '胸闷', '冠心病', '心梗', '房颤', '心律'] },
  { dept: '内分泌科', keywords: ['糖尿病', '血糖', '甲状腺', '甲亢', '甲减', '胰岛素'] },
  { dept: '消化内科', keywords: ['胃镜', '肠镜', '胃疼', '胃痛', '胃病', '胃不舒服', '肠胃', '拉肚子', '腹泻', '便秘', '反酸'] },
  { dept: '呼吸内科', keywords: ['咳嗽', '哮喘', '气管', '肺炎', '肺部', '慢阻肺', '痰多'] },
  { dept: '神经内科', keywords: ['头晕', '头痛', '失眠', '帕金森', '手麻', '手抖', '记性差', '脑梗后'] },
  { dept: '骨科', keywords: ['骨折', '骨质疏松', '腰疼', '腰痛', '腿疼', '腿痛', '膝盖', '关节', '颈椎', '腰椎', '骨头'] },
  { dept: '眼科', keywords: ['眼睛', '眼科', '白内障', '青光眼', '视力', '看不清', '眼花'] },
  { dept: '耳鼻喉科', keywords: ['耳朵', '耳鸣', '听力', '听不清', '鼻炎', '鼻子', '喉咙', '咽喉'] },
  { dept: '口腔科', keywords: ['牙疼', '牙痛', '牙齿', '假牙', '补牙', '拔牙', '口腔'] },
  { dept: '皮肤科', keywords: ['皮肤', '湿疹', '瘙痒', '皮炎', '长疹子'] },
  { dept: '泌尿外科', keywords: ['前列腺', '尿频', '尿急', '结石'] },
  { dept: '体检中心', keywords: ['体检'] }
];

const DEPT_ALIASES: Record<string, string> = {
  '心内科': '心血管内科',
  '心内': '心血管内科',
  '心血管科': '心血管内科',
  '心脏科': '心血管内科',
  '内分泌': '内分泌科',
  '消化科': '消化内科',
  '呼吸科': '呼吸内科',
  '神经科': '神经内科',
  '骨伤科': '骨科',
  '五官科': '耳鼻喉科',
  '牙科': '口腔科',
  '老年科': '老年医学科'
};

const DEPT_SUFFIX_RE: RegExp =
  /(内科|外科|妇科|儿科|眼科|骨科|牙科|口腔科|皮肤科|中医科|急诊科|康复科|疼痛科|营养科|心理科|精神科|耳鼻喉科|五官科|老年科|老年医学科|体检科|放射科|超声科)$/;

/** 医院名称常见后缀（按长度从长到短，便于重叠时取更完整的） */
const HOSPITAL_SUFFIXES: string[] = [
  '社区卫生服务中心', '卫生服务中心', '医学中心', '卫生院', '保健院', '门诊部', '医院', '诊所'
];

/** 医院名前面常见的动词/虚词：抽取时在最后一个出现位置之后截断 */
const BOUNDARY_CHARS: string = '去到在挂找约看是的要想给帮往';

const LEADING_NOISE_RE: RegExp =
  /^(今天|明天|后天|大后天|下下?个?(周|星期|礼拜)[一二三四五六日天]?|这个?(周|星期)[一二三四五六日天]?|(周|星期|礼拜)[一二三四五六日天]|上午|下午|早上|中午|晚上|我|咱|就|还|再|也|先)+/;

const GENERIC_HOSPITAL_PREFIX_RE: RegExp = /^(这|那|哪|什么|附近|大|随便|任何|一家|一个|家门口)/;

const EMERGENCY_TERMS: string[] = [
  '胸痛', '胸口痛', '胸口疼', '心口疼', '呼吸困难', '喘不上气', '喘不过气', '憋气', '昏迷', '晕倒', '昏倒',
  '叫不醒', '意识不清', '摔倒起不来', '大出血', '止不住血', '吐血', '抽搐', '严重过敏',
  '口角歪斜', '嘴歪', '说话不清', '言语不清', '半边身子', '一侧无力', '剧烈头痛'
];

const CANCEL_TERMS: string[] = ['取消', '不用了', '算了', '不去了', '重新来', '重来', '不要了', '先不'];

export class NluRules {

  static containsAny(text: string, words: string[]): boolean {
    for (let i = 0; i < words.length; i++) {
      if (text.indexOf(words[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  static stripPunctuation(text: string): string {
    return text.replace(/[\s，。,.！!？?、：:；;“”"'（）()【】\[\]…~～-]/g, '');
  }

  // ==================== 医院 ====================

  /** 从整句话中抽取医院名；只说了“医院/这家医院”时返回空串 */
  static extractHospital(text: string): string {
    const t: string = NluRules.stripPunctuation(text);
    let bestIdx: number = -1;
    let bestSuffix: string = '';
    for (let i = 0; i < HOSPITAL_SUFFIXES.length; i++) {
      const suffix: string = HOSPITAL_SUFFIXES[i];
      const idx: number = t.indexOf(suffix);
      if (idx < 0) {
        continue;
      }
      if (bestIdx < 0 || idx < bestIdx || (idx === bestIdx && suffix.length > bestSuffix.length)) {
        bestIdx = idx;
        bestSuffix = suffix;
      }
    }
    if (bestIdx < 0) {
      return '';
    }
    let prefix: string = t.substring(Math.max(0, bestIdx - 14), bestIdx);
    for (let i = prefix.length - 1; i >= 0; i--) {
      if (BOUNDARY_CHARS.indexOf(prefix.charAt(i)) >= 0) {
        prefix = prefix.substring(i + 1);
        break;
      }
    }
    prefix = prefix.replace(LEADING_NOISE_RE, '');
    if (prefix.length === 0) {
      // “社区卫生服务中心”本身就是可去的地点；单独的“医院/诊所”只是类别
      return bestSuffix === '社区卫生服务中心' ? bestSuffix : '';
    }
    if (GENERIC_HOSPITAL_PREFIX_RE.test(prefix)) {
      return '';
    }
    return prefix + bestSuffix;
  }

  /**
   * 追问“您想去哪家医院”时，老人常只答“协和”“省中医”。
   * 此时整句回答就是医院名，补上“医院”后缀即可。
   */
  static normalizeHospitalAnswer(text: string): string {
    const full: string = NluRules.extractHospital(text);
    if (full.length > 0) {
      return full;
    }
    let t: string = NluRules.stripPunctuation(text);
    if (/(不知道|随便|都行|不清楚|你定|哪家都行|无所谓)/.test(t)) {
      return '';
    }
    t = t.replace(/^(我想去|我要去|想去|要去|去的是|还是去|还是|就去|我去|去|到|在|就|是)+/, '');
    t = t.replace(/(吧|呢|啊|呀|那家|那个|的)+$/, '');
    if (t.length < 2 || t.length > 16) {
      return '';
    }
    if (NluRules.resolveDepartment(t).length > 0 || DateUtil.parseChineseDate(t, Date.now()).date.length > 0) {
      return '';
    }
    if (t.endsWith('医')) {
      return t + '院';
    }
    return t + '医院';
  }

  // ==================== 科室 ====================

  /** 显式提到的“XX科”，例如“挂心内科”“看眼科” */
  static extractDepartment(text: string): string {
    const t: string = NluRules.stripPunctuation(text);
    const aliasKeys: string[] = Object.keys(DEPT_ALIASES);
    for (let i = 0; i < aliasKeys.length; i++) {
      if (t.indexOf(aliasKeys[i]) >= 0 && t.indexOf(aliasKeys[i] + '医院') < 0) {
        return DEPT_ALIASES[aliasKeys[i]] as string;
      }
    }
    const re: RegExp = /([\u4e00-\u9fa5]{1,6}科)/g;
    let m: RegExpExecArray | null = re.exec(t);
    while (m !== null) {
      let token: string = m[1];
      const next: string = t.charAt(m.index + token.length);
      // 匹配窗口可能带上前面的字（如“人民医院看眼科”），截到最后一个动词/“院”字之后
      token = token.replace(/^.*[看挂去到找院的是在]/, '');
      if (next !== '室' && token.length >= 2 && DEPT_SUFFIX_RE.test(token)) {
        return token;
      }
      m = re.exec(t);
    }
    return '';
  }

  /** 按症状/病种关键词推断科室 */
  static inferDepartment(text: string): string {
    for (let i = 0; i < DEPT_RULES.length; i++) {
      if (NluRules.containsAny(text, DEPT_RULES[i].keywords)) {
        return DEPT_RULES[i].dept;
      }
    }
    return '';
  }

  /** 先看显式科室，再按关键词推断 */
  static resolveDepartment(text: string): string {
    const explicit: string = NluRules.extractDepartment(text);
    return explicit.length > 0 ? explicit : NluRules.inferDepartment(text);
  }

  /** 追问“看什么科”时的回答：优先科室，其次症状 */
  static normalizeDepartmentAnswer(text: string): string {
    const dept: string = NluRules.resolveDepartment(text);
    if (dept.length > 0) {
      return dept;
    }
    if (/(不知道|不清楚|随便)/.test(text)) {
      return '';
    }
    return '';
  }

  // ==================== 意图 ====================

  static guessIntentType(text: string): IntentType {
    if (NluRules.containsAny(text, ['报告', '化验单', '检查结果', '结果出来', '检验单'])) {
      return IntentType.REPORT_QUERY;
    }
    if (NluRules.containsAny(text, ['拿药', '取药', '开药', '配药', '续方', '续药', '药吃完', '药快吃完']) ||
      (text.indexOf('药') >= 0 && NluRules.containsAny(text, ['拿', '取', '开', '配', '买']))) {
      return IntentType.MEDICINE_REFILL;
    }
    if (NluRules.containsAny(text, ['医院', '看病', '复查', '复诊', '挂号', '就诊', '看医生', '门诊', '检查', '体检',
      '挂个号', '看一下', '看看']) ||
      NluRules.resolveDepartment(text).length > 0) {
      return IntentType.MEDICAL_VISIT;
    }
    return IntentType.UNKNOWN;
  }

  static isFollowUpPurpose(text: string): boolean {
    return NluRules.containsAny(text, ['复查', '复诊', '拿药', '取药', '开药', '配药', '续方', '续药']);
  }

  static isEmergency(text: string): boolean {
    return NluRules.containsAny(text, EMERGENCY_TERMS);
  }

  static isCancel(text: string): boolean {
    const t: string = NluRules.stripPunctuation(text);
    if (t.length === 0) {
      return false;
    }
    return NluRules.containsAny(t, CANCEL_TERMS);
  }

  /** 是否在说“已有的安排/预约/提醒” */
  static mentionsJourney(text: string): boolean {
    return NluRules.containsAny(text, ['安排', '预约', '挂号', '提醒', '行程']);
  }

  static isCallFamily(text: string): boolean {
    return NluRules.containsAny(text, ['打电话', '打给', '联系', '叫']) &&
      NluRules.containsAny(text, ['家人', '儿子', '女儿', '老伴', '孩子', '紧急联系人', '闺女', '家里人']);
  }

  /** 对已有安排的提问：DEPART / WHEN / WHERE / BRING / WEATHER，空串表示不是这类问题 */
  static journeyQuestion(text: string): string {
    if (NluRules.containsAny(text, ['几点出发', '几点走', '什么时候出发', '什么时候走', '几点出门', '啥时候走',
      '什么时候出门'])) {
      return 'DEPART';
    }
    if (NluRules.containsAny(text, ['几点看', '几点的号', '哪天看', '什么时候看', '约的几点', '几号看', '哪天去'])) {
      return 'WHEN';
    }
    if (NluRules.containsAny(text, ['在几楼', '几楼', '诊室在哪', '怎么走', '在哪里看', '哪个诊室', '药房在哪',
      '到了医院'])) {
      return 'WHERE';
    }
    if (NluRules.containsAny(text, ['带什么', '要带', '带哪些', '准备什么', '拿什么证', '带啥'])) {
      return 'BRING';
    }
    const asking: boolean = /[吗么？?]|怎么样|如何|会不会|多少度|几度|咋样/.test(text);
    if (asking && NluRules.containsAny(text, ['下雨', '天气', '带伞', '冷不冷', '热不热'])) {
      return 'WEATHER';
    }
    return '';
  }

  static isAnyDate(text: string): boolean {
    return /(都行|随便|尽快|越快越好|最早|哪天都行|你看着办|你定)/.test(text);
  }

  // ==================== 处方/病历文字抽取（离线兜底） ====================

  /**
   * 从 OCR 文字中抽取病历字段，返回与大模型相同格式的 JSON 字符串。
   * 只摘录原文出现的内容；身份证号、医保卡号等长数字会被剔除。
   */
  static extractRecordJson(rawText: string): string {
    const text: string = rawText.replace(/\d{15,19}[Xx]?/g, '');
    const lines: string[] = text.split(/[\r\n]+/);

    const hospital: string = NluRules.extractHospital(text.replace(/[\r\n]+/g, ' '));

    let department: string = '';
    const deptMatch: RegExpMatchArray | null = text.match(/科\s*别\s*[:：]?\s*([\u4e00-\u9fa5]{2,8}科)/);
    if (deptMatch !== null) {
      department = deptMatch[1];
    } else {
      department = NluRules.extractDepartment(text);
    }

    let doctorName: string = '';
    const doctorA: RegExpMatchArray | null = text.match(/(医师|医生|大夫)\s*[:：]\s*([\u4e00-\u9fa5]{2,4})/);
    const doctorB: RegExpMatchArray | null = text.match(/([\u4e00-\u9fa5]{2,4})\s*(主任医师|副主任医师|主治医师)/);
    if (doctorA !== null) {
      doctorName = doctorA[2];
    } else if (doctorB !== null) {
      doctorName = `${doctorB[1]} ${doctorB[2]}`;
    }

    let visitDate: string = '';
    const dateMatch: RegExpMatchArray | null = text.match(/(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})/);
    if (dateMatch !== null) {
      const d: Date | null = DateUtil.makeDate(parseInt(dateMatch[1]), parseInt(dateMatch[2]), parseInt(dateMatch[3]));
      if (d !== null) {
        visitDate = DateUtil.formatDate(d);
      }
    }

    let followUpDays: number = 0;
    const fu: RegExpMatchArray | null =
      text.match(/([0-9一二两三四五六七八九十]{1,3})\s*(天|日|周|星期|个月|月)后?\s*(复诊|复查|随诊|随访|再来|门诊)/);
    if (fu !== null) {
      const n: number = DateUtil.parseChineseNumber(fu[1]);
      if (n > 0) {
        const unit: string = fu[2];
        const factor: number = (unit === '周' || unit === '星期') ? 7 : ((unit === '个月' || unit === '月') ? 30 : 1);
        followUpDays = n * factor;
      }
    }

    const drugLines: string[] = [];
    const drugRe: RegExp = /(片|胶囊|颗粒|口服液|注射液|滴眼液|缓释|mg|毫克|ml|毫升|每日|每天|一日|每晚|每次|qd|bid|tid)/i;
    for (let i = 0; i < lines.length && drugLines.length < 5; i++) {
      const line: string = lines[i].trim();
      if (line.length < 2 || line.length > 60) {
        continue;
      }
      if (/(身份证|医保|卡号|电话|地址|金额|合计|收费)/.test(line)) {
        continue;
      }
      if (drugRe.test(line)) {
        drugLines.push(line);
      }
    }
    let prescription: string = drugLines.join('；');
    if (prescription.length > 200) {
      prescription = prescription.substring(0, 200);
    }

    const obj: Record<string, Object> = {
      'hospital': hospital,
      'department': department,
      'doctorName': doctorName,
      'visitDate': visitDate,
      'followUpDays': followUpDays,
      'prescription': prescription
    };
    return JSON.stringify(obj);
  }
}
