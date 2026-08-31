import { TaskType, TaskStatus, AnomalyType, BusEvent, IntentType } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
import type { ParsedIntent, TaskPlan, TaskNode, RuntimeContext, AgentResult, Anomaly, DeviceNotifyCmd } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/AgentTypes";
import { IntentParser } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/IntentParser";
import { TaskPlanner } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/TaskPlanner";
import { eventBus, blackboard } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/EventBus";
import type { BaseAgent } from './BaseAgent';
import { MedicalAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/MedicalAgent";
import { TravelAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/TravelAgent";
import { NavigationAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/NavigationAgent";
import { ReminderAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/ReminderAgent";
export class CentralAgent {
    /**
     * 全局只应该有一个中枢实例：EntryAbility 的后台巡检（proactiveCheck）
     * 和 Index 页面的用户交互（handleUserRequest）必须共用同一把 running 并发锁，
     * 否则两条调度路径互不知情，可能出现同时抢占 Agent、结果互相覆盖的竞态。
     */
    private static instance: CentralAgent | null = null;
    static getInstance(): CentralAgent {
        if (CentralAgent.instance === null) {
            CentralAgent.instance = new CentralAgent();
        }
        return CentralAgent.instance;
    }
    private agents: Map<string, BaseAgent> = new Map();
    private running: boolean = false;
    private constructor() {
        this.agents.set(TaskType.MEDICAL as string, new MedicalAgent());
        this.agents.set(TaskType.TRAVEL as string, new TravelAgent());
        this.agents.set(TaskType.NAVIGATION as string, new NavigationAgent());
        this.agents.set(TaskType.REMINDER as string, new ReminderAgent());
    }
    /**
     * 主入口：一句话 → 完整陪诊方案
     * @param userText 用户语音转写文本
     * @param rt 运行时上下文
     * @returns 需要用户确认的澄清问题，空串表示无需澄清、已开始执行
     */
    async handleUserRequest(userText: string, rt: RuntimeContext): Promise<string> {
        if (this.running) {
            return '我正在为您安排上一件事，稍等一下';
        }
        // ---- 1. 意图理解 ----
        const intent: ParsedIntent = await IntentParser.parse(userText, rt);
        if (intent.type === IntentType.UNKNOWN || intent.confidence < 0.4) {
            return '我没太听清，您是想去医院看病、还是取药呢？';
        }
        // ---- 2. 槽位澄清：一次只问一个问题 ----
        if (intent.missingSlots.length > 0) {
            return IntentParser.buildClarifyQuestion(intent);
        }
        // ---- 3. 任务规划 ----
        const plan: TaskPlan = TaskPlanner.plan(intent);
        blackboard.setPlan(plan);
        eventBus.emit(BusEvent.PLAN_UPDATED, JSON.stringify(plan));
        // ---- 4. 调度执行 ----
        await this.runPlan(plan, rt);
        return '';
    }
    /**
     * 执行任务 DAG：每轮取出所有依赖已满足的任务并行执行
     * 这是"多 Agent 协同"的实际调度逻辑
     */
    private async runPlan(plan: TaskPlan, rt: RuntimeContext): Promise<void> {
        this.running = true;
        try {
            let guard: number = 0;
            while (!TaskPlanner.isPlanFinished(plan) && guard < 20) {
                guard++;
                const runnable: TaskNode[] = TaskPlanner.getRunnableTasks(plan);
                if (runnable.length === 0) {
                    break; // 有任务失败导致下游永远无法就绪，退出避免死循环
                }
                // 同一层任务并行执行（如出行与导航都只依赖医疗，可同时跑）
                const jobs: Promise<AgentResult>[] = [];
                for (let i = 0; i < runnable.length; i++) {
                    const node: TaskNode = runnable[i];
                    const agent: BaseAgent | undefined = this.agents.get(node.type as string);
                    if (agent === undefined) {
                        node.status = TaskStatus.SKIPPED;
                        continue;
                    }
                    jobs.push(agent.execute(node, rt));
                }
                await Promise.all(jobs);
                // ---- 每轮结束后做一次异常监测 ----
                const anomaly: Anomaly = await this.detectAnomaly(plan, rt);
                if (anomaly.type !== AnomalyType.NONE) {
                    await this.handleAnomaly(plan, anomaly, rt);
                    return;
                }
            }
            // ---- 5. 汇总播报 ----
            this.broadcastSummary(plan);
        }
        finally {
            this.running = false;
        }
    }
    /**
     * 异常监测：医生停诊、恶劣天气、严重拥堵
     * 真实接入时改为订阅医院/天气/交通的变更推送
     */
    private async detectAnomaly(plan: TaskPlan, rt: RuntimeContext): Promise<Anomaly> {
        // 天气突变导致原出行方案不再合适
        if (rt.weather.indexOf('暴雨') >= 0 || rt.weather.indexOf('大雪') >= 0) {
            const travelDone = TaskPlanner.findNode(plan, 'T2');
            if (travelDone !== null && travelDone.status === TaskStatus.SUCCESS) {
                return {
                    type: AnomalyType.HEAVY_RAIN,
                    description: `天气转为${rt.weather}，原出发时间可能来不及`,
                    detectedAt: Date.now(),
                    affectedTasks: ['T2']
                };
            }
        }
        return {
            type: AnomalyType.NONE,
            description: '',
            detectedAt: Date.now(),
            affectedTasks: []
        };
    }
    /** 异常回流：重规划受影响任务及其下游，然后重新执行 */
    private async handleAnomaly(plan: TaskPlan, anomaly: Anomaly, rt: RuntimeContext): Promise<void> {
        eventBus.emit(BusEvent.ANOMALY_DETECTED, JSON.stringify(anomaly));
        // 先主动告知用户，再动手改，避免用户困惑
        this.speak(`${anomaly.description}，我重新帮您安排一下`);
        blackboard.invalidate(anomaly.affectedTasks);
        const newPlan: TaskPlan = TaskPlanner.replan(plan, anomaly);
        blackboard.setPlan(newPlan);
        eventBus.emit(BusEvent.PLAN_UPDATED, JSON.stringify(newPlan));
        this.running = false; // 释放锁，允许重新进入调度
        await this.runPlan(newPlan, rt);
    }
    /**
     * 汇总所有 Agent 的结果，生成一段连贯的口语播报
     * 而不是把四个 Agent 的输出机械拼接
     */
    private broadcastSummary(plan: TaskPlan): void {
        const lines: string[] = [];
        const order: string[] = ['T1', 'T2', 'T3', 'T4'];
        for (let i = 0; i < order.length; i++) {
            const r: AgentResult | undefined = blackboard.getResult(order[i]);
            if (r !== undefined && r.success && r.speech.length > 0) {
                lines.push(r.speech);
            }
        }
        if (lines.length === 0) {
            this.speak('这次没能帮您安排好，我们再试一次好吗');
            return;
        }
        const summary: string = `都安排好了。${lines.join('。')}。您到时候跟着提醒走就行。`;
        this.speak(summary);
        // 同步一张总览卡片到手机
        const cmd: DeviceNotifyCmd = {
            device: 'phone',
            channel: 'card',
            title: '陪诊安排已就绪',
            content: summary
        };
        eventBus.emit(BusEvent.DEVICE_NOTIFY, JSON.stringify(cmd));
    }
    private speak(text: string): void {
        const payload: Record<string, Object> = { 'text': text };
        eventBus.emit(BusEvent.SPEAK, JSON.stringify(payload));
    }
    /**
     * 主动服务入口：由后台定时任务调用
     * 命中到期复诊则主动向用户发起询问
     */
    async proactiveCheck(nowTs: number): Promise<void> {
        const msg: string = await ReminderAgent.scanDueFollowUps(nowTs);
        if (msg.length === 0) {
            return;
        }
        this.speak(msg);
        const cmd: DeviceNotifyCmd = {
            device: 'phone',
            channel: 'card',
            title: '快到复诊时间了',
            content: msg
        };
        eventBus.emit(BusEvent.DEVICE_NOTIFY, JSON.stringify(cmd));
    }
}
