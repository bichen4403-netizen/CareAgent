/**
 * 智护同行 - Agent 间通信总线 + 共享任务状态黑板（Blackboard）
 *
 * 架构图中“共享上下文汇总 / 状态同步 / 冲突消解”的落地实现。
 * 各执行 Agent 不直接互相调用，一律通过总线发消息、通过黑板读写共享状态，
 * 这样新增一个 Agent 不需要改动其它 Agent 的代码。
 */

import { BusEvent, BusMessage, AgentResult, TaskPlan } from './AgentTypes';

type BusHandler = (msg: BusMessage) => void;

class EventBusImpl {
  private handlers: Map<string, BusHandler[]> = new Map<string, BusHandler[]>();

  on(event: BusEvent, handler: BusHandler): void {
    const key: string = event as string;
    let list: BusHandler[] | undefined = this.handlers.get(key);
    if (list === undefined) {
      list = [];
      this.handlers.set(key, list);
    }
    if (list.indexOf(handler) < 0) {
      list.push(handler);
    }
  }

  off(event: BusEvent, handler: BusHandler): void {
    const list: BusHandler[] | undefined = this.handlers.get(event as string);
    if (list === undefined) {
      return;
    }
    const idx: number = list.indexOf(handler);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
  }

  emit(event: BusEvent, payload: string): void {
    const msg: BusMessage = { event: event, payload: payload, ts: Date.now() };
    const list: BusHandler[] | undefined = this.handlers.get(event as string);
    if (list === undefined) {
      return;
    }
    // 复制一份再遍历：处理函数里解绑自己时不会跳过后面的订阅者
    const snapshot: BusHandler[] = list.slice();
    for (let i = 0; i < snapshot.length; i++) {
      try {
        snapshot[i](msg);
      } catch (e) {
        console.error(`[EventBus] handler error on ${event}: ${e}`);
      }
    }
  }
}

/**
 * 共享黑板：所有 Agent 的产出集中在此。
 * 后续 Agent 可读取前序 Agent 的结果（例如出行 Agent 需要读挂号时间来倒推出发时间）。
 * 黑板只保存“本次规划”的中间结果；最终方案由 JourneyStore 持久化到端侧。
 */
class BlackboardImpl {
  private results: Map<string, AgentResult> = new Map<string, AgentResult>();
  private currentPlan: TaskPlan | null = null;

  putResult(taskId: string, result: AgentResult): void {
    this.results.set(taskId, result);
  }

  getResult(taskId: string): AgentResult | undefined {
    return this.results.get(taskId);
  }

  /** 按 Agent 名称查成功的结果，便于跨任务读取 */
  getResultByAgent(agentName: string): AgentResult | undefined {
    let found: AgentResult | undefined = undefined;
    this.results.forEach((v: AgentResult) => {
      if (v.agentName === agentName && v.success) {
        found = v;
      }
    });
    return found;
  }

  setPlan(plan: TaskPlan): void {
    this.currentPlan = plan;
  }

  getPlan(): TaskPlan | null {
    return this.currentPlan;
  }

  /** 重规划时清空受影响任务的旧结果，避免脏数据 */
  invalidate(taskIds: string[]): void {
    for (let i = 0; i < taskIds.length; i++) {
      this.results.delete(taskIds[i]);
    }
  }

  reset(): void {
    this.results.clear();
    this.currentPlan = null;
  }
}

export const eventBus: EventBusImpl = new EventBusImpl();
export const blackboard: BlackboardImpl = new BlackboardImpl();
