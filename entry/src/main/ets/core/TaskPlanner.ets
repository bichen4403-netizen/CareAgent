/**
 * 智护同行 - 任务规划器（中枢层第二步）
 * 把意图拆解为有依赖关系的子任务 DAG，实现“串并行任务编排”。
 *
 * 典型拆解（看病）：
 *   T1 医疗-挂号推荐 ──┬──> T2 出行-路线规划 ──┐
 *                    ├──> T3 导航-院内路线    ├──> T4 提醒-全流程
 *                    └────────────────────────┘
 * T2、T3 只依赖 T1，可并行执行；T4 依赖 T1/T2/T3 全部完成。
 */

import {
  ParsedIntent, TaskPlan, TaskNode, TaskType, TaskStatus, IntentType, Anomaly, AnomalyType
} from './AgentTypes';

export class TaskPlanner {

  static plan(intent: ParsedIntent): TaskPlan {
    const payload: string = JSON.stringify(intent);
    const nodes: TaskNode[] = [];

    if (intent.type === IntentType.MEDICAL_VISIT || intent.type === IntentType.MEDICINE_REFILL) {
      const firstTitle: string = intent.type === IntentType.MEDICINE_REFILL ? '续方取药推荐' : '挂号方案推荐';
      nodes.push(TaskPlanner.newNode('T1', TaskType.MEDICAL, firstTitle, [], payload));
      nodes.push(TaskPlanner.newNode('T2', TaskType.TRAVEL, '出行路线规划', ['T1'], payload));
      nodes.push(TaskPlanner.newNode('T3', TaskType.NAVIGATION, '院内路线指引', ['T1'], payload));
      nodes.push(TaskPlanner.newNode('T4', TaskType.REMINDER, '全流程提醒', ['T1', 'T2', 'T3'], payload));
    }

    const plan: TaskPlan = {
      planId: `plan_${Date.now()}`,
      intent: intent,
      nodes: nodes,
      createdAt: Date.now(),
      version: 1
    };
    return plan;
  }

  /** 找出当前所有依赖已满足、可立即执行的任务（这一批并行执行） */
  static getRunnableTasks(plan: TaskPlan): TaskNode[] {
    const doneIds: Set<string> = new Set<string>();
    for (let i = 0; i < plan.nodes.length; i++) {
      if (plan.nodes[i].status === TaskStatus.SUCCESS) {
        doneIds.add(plan.nodes[i].id);
      }
    }
    const runnable: TaskNode[] = [];
    for (let i = 0; i < plan.nodes.length; i++) {
      const n: TaskNode = plan.nodes[i];
      if (n.status !== TaskStatus.PENDING) {
        continue;
      }
      let ready: boolean = true;
      for (let j = 0; j < n.dependsOn.length; j++) {
        if (!doneIds.has(n.dependsOn[j])) {
          ready = false;
          break;
        }
      }
      if (ready) {
        runnable.push(n);
      }
    }
    return runnable;
  }

  static isPlanFinished(plan: TaskPlan): boolean {
    for (let i = 0; i < plan.nodes.length; i++) {
      const s: TaskStatus = plan.nodes[i].status;
      if (s === TaskStatus.PENDING || s === TaskStatus.RUNNING) {
        return false;
      }
    }
    return true;
  }

  static findNode(plan: TaskPlan, id: string): TaskNode | null {
    for (let i = 0; i < plan.nodes.length; i++) {
      if (plan.nodes[i].id === id) {
        return plan.nodes[i];
      }
    }
    return null;
  }

  /** 受影响任务 + 所有下游任务（传递闭包），重规划时这些任务都要重跑 */
  static affectedClosure(plan: TaskPlan, ids: string[]): string[] {
    const affected: Set<string> = new Set<string>(ids);
    let changed: boolean = true;
    while (changed) {
      changed = false;
      for (let i = 0; i < plan.nodes.length; i++) {
        const n: TaskNode = plan.nodes[i];
        if (affected.has(n.id)) {
          continue;
        }
        for (let j = 0; j < n.dependsOn.length; j++) {
          if (affected.has(n.dependsOn[j])) {
            affected.add(n.id);
            changed = true;
            break;
          }
        }
      }
    }
    const out: string[] = [];
    affected.forEach((id: string) => {
      out.push(id);
    });
    return out;
  }

  /**
   * 异常回流后的局部重规划：只重置受影响任务及其下游，已完成且不受影响的任务保留结果。
   * 例如医生停诊只影响 T1，但 T2/T3/T4 依赖 T1，所以一并重跑；
   * 暴雨只影响 T2，则 T1、T3 保留，T2、T4 重跑。
   */
  static replan(plan: TaskPlan, anomaly: Anomaly): TaskPlan {
    const affected: string[] = TaskPlanner.affectedClosure(plan, anomaly.affectedTasks);
    const anomalyPayload: Record<string, Object> = {
      'anomalyType': anomaly.type as string,
      'description': anomaly.description,
      'detail': anomaly.detail
    };
    for (let i = 0; i < plan.nodes.length; i++) {
      const n: TaskNode = plan.nodes[i];
      if (affected.indexOf(n.id) < 0) {
        continue;
      }
      n.status = TaskStatus.PENDING;
      n.result = '';
      n.errorMsg = '';
      // 把异常信息附加到直接受影响任务的输入中，让 Agent 感知“为什么重做”
      if (anomaly.affectedTasks.indexOf(n.id) >= 0 && anomaly.type !== AnomalyType.NONE) {
        try {
          const orig: Record<string, Object> = JSON.parse(n.payload) as Record<string, Object>;
          orig['anomaly'] = anomalyPayload;
          n.payload = JSON.stringify(orig);
        } catch (e) {
          console.warn(`[TaskPlanner] payload not json, skip anomaly injection: ${e}`);
        }
      }
    }
    plan.version += 1;
    return plan;
  }

  private static newNode(id: string, type: TaskType, title: string, deps: string[], payload: string): TaskNode {
    const node: TaskNode = {
      id: id,
      type: type,
      title: title,
      dependsOn: deps,
      status: TaskStatus.PENDING,
      payload: payload,
      result: '',
      errorMsg: ''
    };
    return node;
  }
}
