import UIAbility from "@ohos:app.ability.UIAbility";
import type AbilityConstant from "@ohos:app.ability.AbilityConstant";
import type Want from "@ohos:app.ability.Want";
import abilityAccessCtrl from "@ohos:abilityAccessCtrl";
import type { Permissions } from "@ohos:abilityAccessCtrl";
import type window from "@ohos:window";
import notificationManager from "@ohos:notificationManager";
import { ContextStore } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/core/ContextStore";
import { DeviceSyncService } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/DeviceSyncService";
import { LLMService, HttpLLMProvider } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/LLMService";
import { CentralAgent } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/agents/CentralAgent";
/**
 * module.json5 里声明的这几个是 user_grant 级权限，光声明不会自动生效，
 * 必须在运行时调用 requestPermissionsFromUser 弹窗申请，否则系统会直接拒绝，
 * 定位、麦克风、跨设备协同、系统代理提醒这些功能会在真机上"看似接了、实际用不了"。
 */
const RUNTIME_PERMISSIONS: Permissions[] = [
    'ohos.permission.LOCATION',
    'ohos.permission.MICROPHONE',
    'ohos.permission.DISTRIBUTED_DATASYNC',
    'ohos.permission.PUBLISH_AGENT_REMINDER'
];
/**
 * ⚠️ 配置项：接入真实大模型
 *
 * 客户端源码中不得保存模型 Token。Demo 默认使用离线 Mock Provider；
 * 后续如需接入真实模型，应通过受控后端代理请求，并在后端保存和轮换密钥。
 * 小艺开放平台通过系统 Agent / Skill 机制接入，不需要在这里配置平台密钥。
 */
const LLM_ENDPOINT: string = '';
const LLM_TOKEN: string = '';
const LLM_MODEL: string = '';
/** 主动服务巡检间隔：4 小时 */
const PROACTIVE_INTERVAL_MS: number = 4 * 3600 * 1000;
export default class EntryAbility extends UIAbility {
    private proactiveTimer: number = -1;
    private central: CentralAgent = CentralAgent.getInstance();
    async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
        console.info('[EntryAbility] onCreate');
        // 端侧记忆初始化
        await ContextStore.getInstance().init(this.context);
        // 运行时权限申请：定位/麦克风/跨设备协同/系统代理提醒
        await this.requestRuntimePermissions();
        // 通知使能：不弹这个开关，手机通知卡片和系统代理提醒到点后都不会显示
        await this.enableNotificationIfNeeded();
        // 注入大模型 Provider
        if (LLM_ENDPOINT.length > 0 && LLM_TOKEN.length > 0 && LLM_MODEL.length > 0) {
            LLMService.setProvider(new HttpLLMProvider(LLM_ENDPOINT, LLM_TOKEN, LLM_MODEL));
            console.info('[EntryAbility] LLM provider: HTTP');
        }
        else {
            console.info('[EntryAbility] LLM provider: Mock (offline)');
        }
        // 跨设备协同服务
        DeviceSyncService.start();
        // 初始化语音合成引擎（失败也不影响其它功能，只是没声音）
        await DeviceSyncService.initTts();
        // 主动服务：定时扫描到期复诊
        this.startProactiveCheck();
    }
    /** 申请 module.json5 里声明过但从未真正弹窗申请过的 user_grant 权限 */
    private async requestRuntimePermissions(): Promise<void> {
        try {
            const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
            await atManager.requestPermissionsFromUser(this.context, RUNTIME_PERMISSIONS);
        }
        catch (e) {
            // 用户拒绝或设备不支持时不阻断启动，相关功能会各自走已有的降级路径
            console.error(`[EntryAbility] requestPermissionsFromUser failed: ${e}`);
        }
    }
    /** 引导用户打开通知开关，否则通知卡片和系统代理提醒都发不出来 */
    private async enableNotificationIfNeeded(): Promise<void> {
        try {
            const enabled: boolean = await notificationManager.isNotificationEnabled();
            if (!enabled) {
                await notificationManager.requestEnableNotification(this.context);
            }
        }
        catch (e) {
            console.error(`[EntryAbility] requestEnableNotification failed: ${e}`);
        }
    }
    private startProactiveCheck(): void {
        // 启动后先跑一次
        this.central.proactiveCheck(Date.now());
        this.proactiveTimer = setInterval(() => {
            this.central.proactiveCheck(Date.now());
        }, PROACTIVE_INTERVAL_MS);
    }
    onDestroy(): void {
        if (this.proactiveTimer >= 0) {
            clearInterval(this.proactiveTimer);
        }
        DeviceSyncService.clearReminders();
        DeviceSyncService.releaseTts();
        console.info('[EntryAbility] onDestroy');
    }
    onWindowStageCreate(windowStage: window.WindowStage): void {
        windowStage.loadContent('pages/Index', (err) => {
            if (err.code) {
                console.error(`[EntryAbility] loadContent failed: ${JSON.stringify(err)}`);
                return;
            }
            console.info('[EntryAbility] loadContent succeeded');
        });
    }
    onForeground(): void {
        // 回到前台立即检查一次，避免用户刚打开就错过提醒
        this.central.proactiveCheck(Date.now());
    }
    onBackground(): void {
        console.info('[EntryAbility] onBackground');
    }
}
