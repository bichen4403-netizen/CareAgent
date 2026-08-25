# 智护同行

**基于多智能体协同的全流程智能陪诊系统**

老人只说一句"我要去第一人民医院拿高血压药"，系统自动完成挂号、出行、导航、提醒全流程。

---

## 一、目录结构

```
zhihu-tongxing/
├── AppScope/
│   ├── app.json5                  # 应用级配置（包名、版本）
│   └── resources/                 # 应用级资源
├── build-profile.json5            # 工程构建配置
├── oh-package.json5               # 依赖管理
├── hvigorfile.ts                  # 构建脚本
├── entry/
│   ├── build-profile.json5
│   ├── oh-package.json5
│   └── src/main/
│       ├── module.json5           # 模块配置（权限、Ability、卡片声明）
│       ├── resources/             # 字符串、颜色、路由表、卡片配置
│       └── ets/
│           ├── core/                      # 中枢调度层
│           │   ├── AgentTypes.ets         # 全局类型定义（Agent 通信协议）
│           │   ├── EventBus.ets           # 事件总线 + 共享黑板
│           │   ├── ContextStore.ets       # 端侧上下文记忆
│           │   ├── IntentParser.ets       # 意图理解 + 历史补槽
│           │   └── TaskPlanner.ets        # DAG 编排 + 异常重规划
│           ├── agents/                    # 多智能体执行层
│           │   ├── BaseAgent.ets          # Agent 基类
│           │   ├── CentralAgent.ets       # 中枢调度 Agent（大脑）
│           │   ├── MedicalAgent.ets       # 医疗协调智能体
│           │   ├── TravelAgent.ets        # 出行协同智能体
│           │   ├── NavigationAgent.ets    # 导航引导智能体
│           │   └── ReminderAgent.ets      # 关怀提醒智能体
│           ├── services/                  # 服务与数据层
│           │   ├── LLMService.ets         # 大模型封装（平台适配层）
│           │   ├── DeviceSyncService.ets  # 跨设备协同 + 语音触达
│           │   └── MockDataSource.ets     # 演示数据源
│           ├── widget/                    # 原子化服务卡片
│           │   ├── CareCardAbility.ets    # 卡片提供方
│           │   ├── CardDataStore.ets      # 跨进程数据桥 + 主动刷新
│           │   └── pages/CareCard.ets     # 卡片 UI
│           ├── pages/
│           │   ├── Index.ets              # 主界面（语音发起 + 进度可视）
│           │   └── JourneyPage.ets        # 陪诊安排详情与确认
│           └── entryability/EntryAbility.ets
└── skills/                        # 小艺开放平台 Skill 定义
    ├── medical-assist/SKILL.md
    ├── travel-plan/SKILL.md
    ├── hospital-nav/SKILL.md
    └── care-reminder/SKILL.md
```

---

## 二、核心设计

### 1. 多智能体协同不是四个独立功能的拼接

四个 Agent 之间有**真实的依赖关系**，这是"连续陪诊"区别于"四个功能按钮"的关键：

```
                  ┌──→ T2 出行（读 T1 的就诊时间，倒推出发）
T1 医疗 ──────────┤
（定就诊时间/诊室）└──→ T3 导航（读 T1 的诊室楼层，规划院内路线）
                            │
                            └──→ T4 提醒（读 T1/T2/T3 的全部时间点）
```

出行 Agent **不自己决定几点出发**，而是从共享黑板读取医疗 Agent 定下的就诊时间倒推。
这就是架构图里「共享上下文汇总 · 冲突消解」的实际落点。

### 2. 异常回流与重规划

`TaskPlanner.replan()` 只重置受影响任务**及其下游**，已完成的无关任务不重跑。
例如天气突变只影响出行（T2）和提醒（T4），挂号（T1）和院内路线（T3）保持不变。

### 3. 端侧记忆驱动的"懂你"

`ContextStore` 记录历史就诊。用户第二次只说"我要拿药"，
`IntentParser.enrichFromHistory()` 自动补出医院、科室、医生，无需再问。

`findDueFollowUps()` 后台扫描到期复诊，提前 3 天**主动**询问用户是否预约——
这是从"等待指令"到"主动陪伴"的转变。

### 4. 跨设备分工有依据，不是硬凑

| 场景 | 设备 | 原因 |
|---|---|---|
| 出发提醒 | 手表震动 | 手机常在包里，老人看不到；手表贴身 |
| 院内导航 | 耳机语音 | 双手解放，不用边走边看屏幕 |
| 证件/方案确认 | 手机卡片 | 信息量大，需要看清楚 |

---

## 三、鸿蒙特性集成清单

赛题要求集成 3 个以上鸿蒙特性，本项目实际用到 5 个，且每个都是**功能刚需而非装饰**：

| 特性 | 落点 | 为什么非用不可 |
|---|---|---|
| 原子化服务卡片 | `widget/` | 老人不用打开 App，桌面直接看到"下一步该做什么" |
| 分布式软总线 / 多设备协同 | `DeviceSyncService.notifyWatch()` | 手机常在包里看不到，出发提醒必须走手表震动 |
| 位置感知 | `Index.buildRuntimeContext()` | 出发时间要按实时位置和路况倒推 |
| 后台代理提醒 | `DeviceSyncService.scheduleReminders()` | App 退到后台仍要按时提醒出发和用药 |
| 语音交互 | `Index.onVoiceTap()` / TTS 播报 | 老年用户的主要交互方式，降低操作门槛 |

---

## 四、运行方式

### 环境

- DevEco Studio（建议使用最新稳定版）
- 真机或模拟器

### 导入工程

1. DevEco Studio → Open → 选择本工程根目录
2. 等待 Sync，若提示 SDK 版本不匹配，在 `build-profile.json5` 中把
   `compatibleSdkVersion` 改成你本地已安装的版本
3. `entry/src/main/resources/base/media/` 下需要一个 `icon.png`，
   `AppScope/resources/base/media/` 下需要 `app_icon.png` ——
   可从任意 DevEco 新建工程复制一份过来
4. 直接运行 —— **默认使用离线 Mock 数据，无需任何配置和网络**
5. 点击"按住说话"按钮，即可看到完整陪诊流程演示

### 接入真实大模型

编辑 `entryability/EntryAbility.ets` 顶部配置：

```typescript
const LLM_ENDPOINT: string = 'https://your-endpoint/v1/chat/completions';
const LLM_TOKEN: string = 'your-token';
const LLM_MODEL: string = 'your-model';
```

留空则自动降级到离线 Mock，答辩现场断网也能完整演示。

### 接入小艺开放平台

`skills/` 下四个 SKILL.md 是按能力边界拆分好的技能定义，
到小艺开放平台创建 Skill 时可直接作为技能描述与执行流程的依据。

> ⚠️ 小艺开放平台的 Agent / Skill 具体 SDK 接口、参数格式请以
> 华为开发者联盟官方最新文档为准。本项目已把平台耦合点收敛在
> `services/LLMService.ets` 的 `LLMProvider` 接口，
> 接平台时新增一个 Provider 实现即可，上层 Agent 代码无需改动。

---

## 五、待接入的真实能力

代码中标注 `TODO` 的位置，是需要替换为真实系统能力的点：

| 位置 | 待接入能力 |
|---|---|
| `Index.ets` `onVoiceTap()` | 系统语音识别 |
| `Index.ets` `buildRuntimeContext()` | 定位服务获取真实经纬度 |
| `DeviceSyncService.speak()` | 系统语音合成（老年模式：语速放慢、音量提高） |
| `DeviceSyncService.notifyWatch()` | 分布式流转，把提醒发送到手表侧 Ability |
| `DeviceSyncService.scheduleReminders()` | 后台代理提醒，保证退到后台仍能触发 |
| `MockDataSource` 全部方法 | 医院挂号接口 / 地图出行服务 / 院内定位 |
| `widget/CareCardAbility.ets` | 卡片刷新已实现，需确认 FormKit API 版本适配 |

---

## 六、安全与合规边界

这部分建议在答辩时主动讲，属于加分项：

- **不做任何诊断和用药建议**，用药提醒只复述医生已开具的处方内容
- 挂号、叫车等**产生费用的操作必须用户显式确认**，不自动下单
- 健康数据、就诊记录**仅存端侧**，不上传云端
- 位置信息仅用于当次行程规划，不做轨迹留存
- 提醒频率克制，同时段多条提醒合并，用户可关闭任意类别

---

## 七、演示脚本建议

按"一次完整就医"演示，比逐个功能点罗列更有说服力：

1. 点击语音按钮，说"我要去第一人民医院拿高血压药"
2. 观察进度面板：四个 Agent 依次点亮，展示协同过程
3. 进入"陪诊记录"页，展示汇总方案（就诊/出行/院内路线/提醒清单）
4. 重点讲提醒清单的**设备分工**——每条提醒为什么用手表/耳机/手机
5. 点击确认，提醒注册成功
6. 补充说明：下次用户只说"我要拿药"，系统能自动补全医院科室医生
