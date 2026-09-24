/**
 * 智护同行 - 执行 Agent 基类
 *
 * 所有专业 Agent 继承此类，统一：
 *  - 执行入口 execute()
 *  - 超时与异常兜底（单个 Agent 失败不拖垮整条陪诊链路，进度卡片不会永远转圈）
 *  - 结果写入共享黑板、通过事件总线上报状态
 */

import {
  AgentResult, TaskNode, RuntimeContext, BusEvent, TaskStatus, DataSourceType, VerificationStatus
} from '../core/AgentTypes';
import { eventBus, blackboard } from '../core/EventBus';

export abstract class BaseAgent {
  abstract readonly name: string;

  /** 单个任务最长等待时间：网关天气 + 路线并发请求各 8 秒，留足余量 */
  private static readonly TASK_TIMEOUT_MS: number = 20000;

  /** 子类实现具体业务逻辑 */
  protected abstract run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult>;

  /** 统一执行入口 */
  async execute(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    task.status = TaskStatus.RUNNING;
    const startPayload: Record<string, Object> = {
      'taskId': task.id,
      'agent': this.name,
      'title': task.title
    };
    eventBus.emit(BusEvent.TASK_STARTED, JSON.stringify(startPayload));
    console.info(`[${this.name}] task ${task.id} (${task.title}) started`);

    const result: AgentResult = await BaseAgent.withTimeout(this.run(task, rt), BaseAgent.TASK_TIMEOUT_MS,
      task, this.name);

    task.status = result.success ? TaskStatus.SUCCESS : TaskStatus.FAILED;
    task.result = result.data;
    task.errorMsg = result.errorMsg;
    console.info(`[${this.name}] task ${task.id} finished: success=${result.success}` +
      (result.errorMsg.length > 0 ? `, err=${result.errorMsg}` : ''));
    blackboard.putResult(task.id, result);
    eventBus.emit(BusEvent.TASK_FINISHED, JSON.stringify(result));
    return result;
  }

  /**
   * 给 run() 套一层超时和异常兜底，保证 execute() 一定在有限时间内拿到结果。
   * 超时后 run() 若再完成，结果会被忽略，避免“先判失败、后又改成功”的状态错乱。
   */
  private static withTimeout(task: Promise<AgentResult>, ms: number, node: TaskNode,
    agentName: string): Promise<AgentResult> {
    return new Promise<AgentResult>((resolve: (r: AgentResult) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        console.error(`[${agentName}] task ${node.id} timeout after ${ms}ms`);
        resolve(BaseAgent.failure(node.id, agentName, `${node.title}这一步等太久了，您可以稍后再说一次`,
          'ERR_TIMEOUT'));
      }, ms);
      task.then((r: AgentResult) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(r);
      }).catch((e: Error) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        console.error(`[${agentName}] task ${node.id} execute error: ${e}`);
        resolve(BaseAgent.failure(node.id, agentName, `${node.title}这一步暂时没能完成`, `${e}`));
      });
    });
  }

  private static failure(taskId: string, agentName: string, speech: string, err: string): AgentResult {
    const r: AgentResult = {
      taskId: taskId,
      agentName: agentName,
      success: false,
      speech: speech,
      data: '',
      needConfirm: false,
      errorMsg: err,
      dataSource: DataSourceType.UNKNOWN,
      verificationStatus: VerificationStatus.UNVERIFIED,
      updatedAt: Date.now()
    };
    return r;
  }

  protected ok(taskId: string, speech: string, data: string, needConfirm: boolean,
    dataSource: DataSourceType, verificationStatus: VerificationStatus): AgentResult {
    const r: AgentResult = {
      taskId: taskId,
      agentName: this.name,
      success: true,
      speech: speech,
      data: data,
      needConfirm: needConfirm,
      errorMsg: '',
      dataSource: dataSource,
      verificationStatus: verificationStatus,
      updatedAt: Date.now()
    };
    return r;
  }

  protected fail(taskId: string, speech: string, err: string): AgentResult {
    return BaseAgent.failure(taskId, this.name, speech, err);
  }

  // ==================== 解析工具 ====================

  /** 任务输入（意图 JSON）→ Record；解析失败返回空对象 */
  protected static payloadOf(task: TaskNode): Record<string, Object> {
    return BaseAgent.parseRecord(task.payload);
  }

  protected static parseRecord(raw: string): Record<string, Object> {
    try {
      const v: Object = JSON.parse(raw) as Object;
      if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
        return v as Record<string, Object>;
      }
    } catch (e) {
      console.warn(`[BaseAgent] json parse failed: ${e}`);
    }
    const empty: Record<string, Object> = {};
    return empty;
  }

  /** 重规划时注入的异常信息，没有则返回 null */
  protected static anomalyOf(payload: Record<string, Object>): Record<string, Object> | null {
    const a: Object | undefined = payload['anomaly'];
    if (a !== undefined && a !== null && typeof a === 'object') {
      return a as Record<string, Object>;
    }
    return null;
  }

  protected static strOf(obj: Record<string, Object>, key: string): string {
    const v: Object | undefined = obj[key];
    return typeof v === 'string' ? v : '';
  }

  protected static boolOf(obj: Record<string, Object>, key: string): boolean {
    const v: Object | undefined = obj[key];
    return v === true;
  }

  protected static numOf(obj: Record<string, Object>, key: string, def: number): number {
    const v: Object | undefined = obj[key];
    return typeof v === 'number' && isFinite(v) ? v : def;
  }
}
