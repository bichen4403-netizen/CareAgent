/**
 * 智护同行 - 执行 Agent 基类
 *
 * 所有专业 Agent 继承此类，统一：
 *  - 执行入口 execute()
 *  - 失败兜底（不让单个 Agent 失败拖垮整条陪诊链路）
 *  - 结果写入共享黑板
 *  - 通过事件总线上报状态
 */

import { AgentResult, TaskNode, RuntimeContext, BusEvent, TaskStatus } from '../core/AgentTypes';
import { eventBus, blackboard } from '../core/EventBus';

export abstract class BaseAgent {
  abstract readonly name: string;

  /** 子类实现具体业务逻辑 */
  protected abstract run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult>;

  /** 统一执行入口，带异常兜底与状态上报 */
  async execute(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
    task.status = TaskStatus.RUNNING;
    const startPayload: Record<string, Object> = {
      'taskId': task.id,
      'agent': this.name,
      'title': task.title
    };
    eventBus.emit(BusEvent.TASK_STARTED, JSON.stringify(startPayload));

    let result: AgentResult;
    try {
      result = await this.run(task, rt);
    } catch (e) {
      console.error(`[${this.name}] execute error: ${e}`);
      result = {
        taskId: task.id,
        agentName: this.name,
        success: false,
        speech: `${task.title}这一步暂时没能完成，我稍后再试一次`,
        data: '',
        needConfirm: false,
        errorMsg: `${e}`
      };
    }

    task.status = result.success ? TaskStatus.SUCCESS : TaskStatus.FAILED;
    task.result = result.data;
    task.errorMsg = result.errorMsg;

    blackboard.putResult(task.id, result);
    eventBus.emit(BusEvent.TASK_FINISHED, JSON.stringify(result));
    return result;
  }

  protected ok(taskId: string, speech: string, data: string, needConfirm: boolean): AgentResult {
    return {
      taskId: taskId,
      agentName: this.name,
      success: true,
      speech: speech,
      data: data,
      needConfirm: needConfirm,
      errorMsg: ''
    };
  }

  protected fail(taskId: string, speech: string, err: string): AgentResult {
    return {
      taskId: taskId,
      agentName: this.name,
      success: false,
      speech: speech,
      data: '',
      needConfirm: false,
      errorMsg: err
    };
  }
}
