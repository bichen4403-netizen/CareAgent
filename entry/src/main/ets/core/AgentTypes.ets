/**
 * 智护同行 - 核心类型定义
 * 所有 Agent 之间传递的数据结构统一在此定义，保证类型安全与协议一致
 */

// ==================== 意图与任务 ====================

/** 用户意图类型 */
export enum IntentType {
  MEDICAL_VISIT = 'MEDICAL_VISIT',       // 就诊/复查
  MEDICINE_REFILL = 'MEDICINE_REFILL',   // 取药/续方
  REPORT_QUERY = 'REPORT_QUERY',         // 报告查询
  UNKNOWN = 'UNKNOWN'
}

/** 意图解析结果（中枢层输出） */
export interface ParsedIntent {
  type: IntentType;
  hospital: string;          // 目标医院，可为空（需澄清）
  department: string;        // 科室
  purpose: string;           // 原始诉求描述
  expectedDate: string;      // 期望日期 YYYY-MM-DD，空表示未指定
  isRevisit: boolean;        // 是否复诊
  confidence: number;        // 0~1
  missingSlots: string[];    // 缺失且需向用户澄清的槽位
}

/** 任务类型 —— 对应四个执行 Agent */
export enum TaskType {
  MEDICAL = 'MEDICAL',
  TRAVEL = 'TRAVEL',
  NAVIGATION = 'NAVIGATION',
  REMINDER = 'REMINDER'
}

/** 任务状态 */
export enum TaskStatus {
  PENDING = 'PENDING',
  RUNNING = 'RUNNING',
  SUCCESS = 'SUCCESS',
  FAILED = 'FAILED',
  SKIPPED = 'SKIPPED'
}

/** 单个任务节点 */
export interface TaskNode {
  id: string;
  type: TaskType;
  title: string;
  dependsOn: string[];       // 依赖的任务 id，用于串并行编排
  status: TaskStatus;
  payload: string;           // JSON 字符串，任务输入
  result: string;            // JSON 字符串，任务输出
  errorMsg: string;
}

/** 任务执行计划（DAG） */
export interface TaskPlan {
  planId: string;
  intent: ParsedIntent;
  nodes: TaskNode[];
  createdAt: number;
  version: number;           // 每次重规划 +1
}

// ==================== Agent 执行结果 ====================

/** Agent 统一返回结构 */
export interface AgentResult {
  taskId: string;
  agentName: string;
  success: boolean;
  /** 给用户听的自然语言摘要（用于语音播报） */
  speech: string;
  /** 结构化数据，JSON 字符串 */
  data: string;
  /** 是否需要用户确认后才能继续 */
  needConfirm: boolean;
  errorMsg: string;
}

// ==================== 业务领域模型 ====================

/** 挂号方案 */
/** 挂号方案的确认状态 —— 明确"AI 只是推荐，不是真的挂上了" */
export enum BookingStatus {
  RECOMMENDED = 'RECOMMENDED',           // AI 生成的推荐方案，还没在官方渠道操作
  AWAITING_OFFICIAL = 'AWAITING_OFFICIAL', // 已跳转官方渠道，等用户回来确认结果
  CONFIRMED = 'CONFIRMED'                // 用户确认已在官方渠道完成挂号
}

/** 挂号方案（AI 推荐，需在官方渠道最终确认，不代表已经挂号成功） */
export interface Appointment {
  hospitalName: string;
  hospitalAddress: string;
  department: string;
  doctorName: string;
  visitDate: string;         // YYYY-MM-DD
  visitTime: string;         // HH:mm
  registrationFee: number;
  queueNo: string;
  buildingName: string;      // 门诊楼
  floor: string;             // 楼层
  roomNo: string;            // 诊室
  bookingStatus: BookingStatus;
  officialChannelName: string;   // 建议去哪个官方渠道确认，如"京医通""浙里办"
}

/** 出行方案 */
export interface TravelPlan {
  originAddress: string;
  destAddress: string;
  departTime: string;        // HH:mm 建议出发时间
  durationMin: number;       // 预计车程（分钟）
  distanceKm: number;
  trafficLevel: string;      // 畅通 / 缓行 / 拥堵
  weather: string;           // 晴 / 雨 / 雪
  bufferMin: number;         // 因天气或拥堵额外预留的分钟数
  suggestion: string;
}

/** 院内导航步骤 */
export interface NavStep {
  order: number;
  instruction: string;
  landmark: string;
}

/** 院内导航方案 */
export interface IndoorNavPlan {
  entrance: string;
  targetRoom: string;
  steps: NavStep[];
  estimatedWalkMin: number;
}

/** 提醒项 */
export interface ReminderItem {
  id: string;
  title: string;
  content: string;
  triggerAt: number;         // 时间戳
  targetDevice: string;      // phone / watch / earphone
  channel: string;           // card / vibrate / voice
  fired: boolean;
}

// ==================== 上下文与用户档案 ====================

/** 用户档案（端侧存储，用户主动授权后写入） */
export interface UserProfile {
  name: string;
  age: number;
  homeAddress: string;
  preferredHospitals: string[];   // 常去医院
  chronicTags: string[];          // 慢病标签
  accessibilityMode: boolean;     // 大字体与语音优先
  emergencyContact: string;
}

/** 病历记录的采集来源 —— 不同来源可信度不同，写入前都需用户确认 */
export enum RecordSource {
  USER_SPOKEN = 'USER_SPOKEN',     // 对话口述，仅作线索，最不可靠
  OCR_SCAN = 'OCR_SCAN',           // 拍照识别处方/检查单，最可靠
  POST_VISIT_ASK = 'POST_VISIT_ASK', // 陪诊结束后系统主动询问
  MANUAL_INPUT = 'MANUAL_INPUT'    // 家属/本人手动建档
}

/** 一次历史服务记录（用于下次复诊自动提前规划） */
export interface ServiceRecord {
  recordId: string;
  hospital: string;
  department: string;
  doctorName: string;
  visitDate: string;
  followUpDays: number;      // 医生建议的复诊间隔天数，0 表示无
  prescription: string;
  source: RecordSource;      // 这条记录是怎么来的
  confirmed: boolean;        // 用户是否已确认过，未确认的记录不用于自动决策
}

/** 运行时上下文快照 */
export interface RuntimeContext {
  currentLat: number;
  currentLng: number;
  currentAddress: string;
  nowTs: number;
  weather: string;
  trafficLevel: string;
}

// ==================== 异常与重规划 ====================

export enum AnomalyType {
  DOCTOR_OFF = 'DOCTOR_OFF',                     // 医生停诊
  HEAVY_RAIN = 'HEAVY_RAIN',                     // 恶劣天气
  TRAFFIC_JAM = 'TRAFFIC_JAM',                   // 严重拥堵
  APPOINTMENT_CHANGED = 'APPOINTMENT_CHANGED',
  NONE = 'NONE'
}

export interface Anomaly {
  type: AnomalyType;
  description: string;
  detectedAt: number;
  affectedTasks: string[];   // 受影响的任务 id
}

// ==================== 事件总线消息 ====================

export enum BusEvent {
  TASK_STARTED = 'TASK_STARTED',
  TASK_FINISHED = 'TASK_FINISHED',
  PLAN_UPDATED = 'PLAN_UPDATED',
  ANOMALY_DETECTED = 'ANOMALY_DETECTED',
  SPEAK = 'SPEAK',                     // 请求语音播报
  DEVICE_NOTIFY = 'DEVICE_NOTIFY'      // 请求跨设备触达
}

export interface BusMessage {
  event: BusEvent;
  payload: string;
  ts: number;
}

/** 跨设备触达指令 */
export interface DeviceNotifyCmd {
  device: string;    // phone / watch / earphone
  channel: string;   // card / vibrate / voice
  title: string;
  content: string;
}
