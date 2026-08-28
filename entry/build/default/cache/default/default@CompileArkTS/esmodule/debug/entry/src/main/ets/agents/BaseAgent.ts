import { BusEvent, TaskStatus } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
import type { AgentResult, TaskNode, RuntimeContext } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
import { eventBus, blackboard } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/EventBus";
export abstract class BaseAgent {
    abstract readonly name: string;
    /**
     * 单个任务的最长等待时间。
     * 之前 run() 一旦因为任何原因(网络卡住、真机 API 行为异常等)没能 resolve/reject，
     * 进度卡片就会永远停在"处理中"，用户完全看不出系统是卡住了还是真的在算。
     * 加上超时后，最坏情况也会在这个时间点强制判定失败，把"无限转圈"变成"明确的失败反馈"。
     */
    private static readonly TASK_TIMEOUT_MS: number = 15000;
    /** 子类实现具体业务逻辑 */
    protected abstract run(task: TaskNode, rt: RuntimeContext): Promise<AgentResult>;
    /** 统一执行入口，带异常兜底、超时兜底与状态上报 */
    async execute(task: TaskNode, rt: RuntimeContext): Promise<AgentResult> {
        task.status = TaskStatus.RUNNING;
        const startPayload: Record<string, Object> = {
            'taskId': task.id,
            'agent': this.name,
            'title': task.title
        };
        eventBus.emit(BusEvent.TASK_STARTED, JSON.stringify(startPayload));
        console.info(`[${this.name}] task ${task.id} (${task.title}) started`);
        const result: AgentResult = await BaseAgent.withTimeout(this.run(task, rt), BaseAgent.TASK_TIMEOUT_MS, task, this.name);
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
     * 给 run() 套一层超时和异常兜底，保证不管发生什么，execute() 一定能在有限时间内拿到结果。
     * run() 本身若最终还是完成了（超时之后才 resolve），结果会被忽略，不会二次上报状态，
     * 避免出现"先判超时失败、后面又悄悄改成成功"的状态错乱。
     */
    private static withTimeout(task: Promise<AgentResult>, ms: number, node: TaskNode, agentName: string): Promise<AgentResult> {
        return new Promise<AgentResult>((resolve: (r: AgentResult) => void) => {
            let settled: boolean = false;
            const timer: number = setTimeout(() => {
                if (settled) {
                    return;
                }
                settled = true;
                console.error(`[${agentName}] task ${node.id} timeout after ${ms}ms`);
                const timeoutResult: AgentResult = {
                    taskId: node.id,
                    agentName: agentName,
                    success: false,
                    speech: `${node.title}这一步等太久了，我们稍后再试一次`,
                    data: '',
                    needConfirm: false,
                    errorMsg: 'ERR_TIMEOUT'
                };
                resolve(timeoutResult);
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
                const errorResult: AgentResult = {
                    taskId: node.id,
                    agentName: agentName,
                    success: false,
                    speech: `${node.title}这一步暂时没能完成，我稍后再试一次`,
                    data: '',
                    needConfirm: false,
                    errorMsg: `${e}`
                };
                resolve(errorResult);
            });
        });
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
