import { TaskType, TaskStatus, IntentType } from "@bundle:com.example.zhihutongxing/entry/ets/core/AgentTypes";
import type { TaskPlan, TaskNode, ParsedIntent, Anomaly } from "@bundle:com.example.zhihutongxing/entry/ets/core/AgentTypes";
export class TaskPlanner {
    /** 首次规划：根据意图生成完整任务 DAG */
    static plan(intent: ParsedIntent): TaskPlan {
        const nodes: TaskNode[] = [];
        // T1 医疗：查号源排班、确定就诊时间与诊室
        nodes.push(TaskPlanner.newNode('T1', TaskType.MEDICAL, '确认就诊安排', [], intent));
        // T2 出行：依赖 T1 的就诊时间，倒推出发时间
        nodes.push(TaskPlanner.newNode('T2', TaskType.TRAVEL, '规划出行方案', ['T1'], intent));
        // T3 导航：依赖 T1 的诊室楼层信息
        nodes.push(TaskPlanner.newNode('T3', TaskType.NAVIGATION, '生成院内路线', ['T1'], intent));
        // T4 提醒：依赖 T1/T2/T3 的全部时间节点
        nodes.push(TaskPlanner.newNode('T4', TaskType.REMINDER, '设置全流程提醒', ['T1', 'T2', 'T3'], intent));
        // 取药场景导航目标是药房而非诊室
        if (intent.type === IntentType.MEDICINE_REFILL) {
            nodes[2].title = '生成取药路线';
        }
        return {
            planId: `plan_${Date.now()}`,
            intent: intent,
            nodes: nodes,
            createdAt: Date.now(),
            version: 1
        };
    }
    private static newNode(id: string, type: TaskType, title: string, deps: string[], intent: ParsedIntent): TaskNode {
        return {
            id: id,
            type: type,
            title: title,
            dependsOn: deps,
            status: TaskStatus.PENDING,
            payload: JSON.stringify(intent),
            result: '',
            errorMsg: ''
        };
    }
    /**
     * 重规划：异常发生时只重置受影响的任务及其下游，已完成的无关任务不重跑
     * 对应流程图中的「异常回流 → 触发重规划」
     */
    static replan(oldPlan: TaskPlan, anomaly: Anomaly): TaskPlan {
        const affected: Set<string> = new Set<string>();
        for (let i = 0; i < anomaly.affectedTasks.length; i++) {
            affected.add(anomaly.affectedTasks[i]);
        }
        // 沿依赖关系向下游传播
        let changed: boolean = true;
        while (changed) {
            changed = false;
            for (let i = 0; i < oldPlan.nodes.length; i++) {
                const n: TaskNode = oldPlan.nodes[i];
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
        const newNodes: TaskNode[] = [];
        for (let i = 0; i < oldPlan.nodes.length; i++) {
            const n: TaskNode = oldPlan.nodes[i];
            if (affected.has(n.id)) {
                newNodes.push({
                    id: n.id,
                    type: n.type,
                    title: n.title,
                    dependsOn: n.dependsOn,
                    status: TaskStatus.PENDING,
                    payload: TaskPlanner.injectAnomaly(n.payload, anomaly),
                    result: '',
                    errorMsg: ''
                });
            }
            else {
                newNodes.push(n);
            }
        }
        return {
            planId: oldPlan.planId,
            intent: oldPlan.intent,
            nodes: newNodes,
            createdAt: oldPlan.createdAt,
            version: oldPlan.version + 1
        };
    }
    /** 把异常信息塞进任务输入，让 Agent 知道按什么新约束重新算 */
    private static injectAnomaly(payload: string, anomaly: Anomaly): string {
        try {
            const obj: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
            obj['anomalyType'] = anomaly.type as string;
            obj['anomalyDesc'] = anomaly.description;
            return JSON.stringify(obj);
        }
        catch (e) {
            return payload;
        }
    }
    /** 取出当前所有依赖已满足、可立即执行的任务（支持并行） */
    static getRunnableTasks(plan: TaskPlan): TaskNode[] {
        const statusMap: Map<string, TaskStatus> = new Map();
        for (let i = 0; i < plan.nodes.length; i++) {
            statusMap.set(plan.nodes[i].id, plan.nodes[i].status);
        }
        const runnable: TaskNode[] = [];
        for (let i = 0; i < plan.nodes.length; i++) {
            const n: TaskNode = plan.nodes[i];
            if (n.status !== TaskStatus.PENDING) {
                continue;
            }
            let ready: boolean = true;
            for (let j = 0; j < n.dependsOn.length; j++) {
                if (statusMap.get(n.dependsOn[j]) !== TaskStatus.SUCCESS) {
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
}
