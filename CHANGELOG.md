# 变更说明 · v1.1

本版修复了上一版中会导致功能实际失效的问题，补齐了“挂号 → 出行 → 院内 → 复诊”的完整闭环，并重写了服务端网关。源码层面没有需要删除的文件。

---

## 一、怎么替换

你的工程是 Git 仓库，推荐在原工程上覆盖，提交记录和分支都会保留：

1. 把压缩包里 `agent/` 目录下的全部内容复制到原工程根目录（与 `entry`、`AppScope` 同级），同名文件直接覆盖。
2. 删除第二节列出的目录。
3. DevEco：File → Sync and Refresh Project，然后 Build → Clean Project，再运行。
4. 用 `git status` 核对改动，再按 PHASE1_GUIDE.md 里的流程提交。

只想先看效果的话，也可以解压后用 DevEco Studio 直接打开 `agent/` 目录。它是完整的干净工程，不含构建缓存、`.idea` 和 `.git`。

演示机上装过旧版的话，建议先卸载旧版再安装新版，避免旧版数据和旧版注册的提醒残留。

---

## 二、需要删除的内容

| 路径 | 原因 |
|---|---|
| `.idea/shelf/` | 两个搁置补丁，里面只有旧的构建日志 |
| `.hvigor/` | 构建缓存，DevEco 会自动重建 |
| `entry/build/` | 旧的构建产物（含旧版 HAP），避免误装 |

`entry/src/main/ets/` 下的旧文件全部被同路径的新文件替换，没有需要单独删除的源码文件。

---

## 三、文件清单

### 替换（47 个）

```
README.md
PHASE1_GUIDE.md
.gitignore
entry/src/main/module.json5
entry/src/main/resources/base/profile/main_pages.json
entry/src/main/resources/base/media/agent_avatar.png        （压缩到 320px，约 98KB）
entry/src/main/ets/agents/        BaseAgent、CentralAgent、MedicalAgent、NavigationAgent、ReminderAgent、TravelAgent（6 个）
entry/src/main/ets/config/        BackendConfig
entry/src/main/ets/core/          AgentTypes、ContextStore、EventBus、IntentParser、TaskPlanner（5 个）
entry/src/main/ets/entryability/  EntryAbility
entry/src/main/ets/pages/         Index、JourneyPage（2 个）
entry/src/main/ets/services/      AppLinkService、DeviceSyncService、LLMService、MedicalAssistService、MockDataSource、
                                  OcrCaptureService、SpeechInputService、TravelService、WeatherService（9 个）
entry/src/main/ets/widget/        CardDataStore、CareCardAbility、pages/CareCard（3 个）
entry/skills/travel-plan/         SKILL.md、scripts/TravelPlanSkill.ets
entry/skills/hospital-nav/        SKILL.md、scripts/HospitalNavSkill.ets
entry/skills/care-reminder/       SKILL.md、scripts/CareReminderSkill.ets
backend/                          .env.example、Dockerfile、README.md、
                                  app/config.py、app/main.py、app/models.py、app/providers.py、tests/test_api.py
```

### 新增（15 个）

```
CHANGELOG.md
entry/src/main/ets/core/AppBootstrap.ets
entry/src/main/ets/core/DateUtil.ets
entry/src/main/ets/core/JourneyStore.ets
entry/src/main/ets/core/NluRules.ets
entry/src/main/ets/pages/NavGuidePage.ets
entry/src/main/ets/pages/ProfilePage.ets
entry/src/main/ets/services/BackendClient.ets
entry/src/main/ets/services/HospitalService.ets
entry/src/main/ets/services/LocationService.ets
entry/src/main/ets/services/RuntimeContextService.ets
entry/src/main/ets/utils/PermissionHelper.ets
entry/src/main/ets/utils/UiLabels.ets
entry/src/main/resources/base/media/startIcon.png
backend/.dockerignore
```

### 未改动

`AppScope/`、`hvigor/`、根目录与 `entry/` 的构建配置、`local.properties`、`entry/skills/medical-assist/`、字符串和颜色资源、`form_config.json`、`backend/requirements.txt`、`backend/pytest.ini`、`.github/workflows/`。

---

## 四、修复的问题

### 会导致功能实际失效的

1. **语音播报没有声音**：语音合成引擎参数改为官方要求的 `online: 1`、`audioType: 'pcm'`，并修正了写反的队列模式注释。
2. **真机语音识别收不到结果**：改为由识别引擎自己录音，不再手动写入大小不固定的音频块；支持边说边出字、说完停顿自动结束。
3. **语音失败时冒充用户下单**：识别失败不再自动提交演示语句，而是提示打字或去开启麦克风；按钮文案与实际交互一致（“点我说话 / 说完了，点我结束”）。
4. **权限申请错误**：定位时同时申请模糊和精确位置；移除从未使用的 `DISTRIBUTED_DATASYNC`、`KEEP_BACKGROUND_RUNNING`；启动时不再一次弹出全部权限，改为用到时再申请，被拒后引导去设置页。
5. **陪诊方案只存在内存里**：新增 `JourneyStore` 持久化方案和确认状态。跳去官方渠道后 App 被回收也不丢，退出再进来不会重复确认、重复写提醒和病历。
6. **系统提醒无法撤销、点了打不开 App**：重新注册前先取消本应用的全部旧提醒，重规划不再叠加；每条提醒都能直达“陪诊安排 / 院内引导 / 首页”，并带“关闭 / 稍后提醒”按钮。

### 逻辑与体验缺口

7. **日期理解**：“下周三”按自然周计算，不再是今天加 7 天；新增大后天、下下周、几号、几月几日、下个月几号、几天后、过两天等说法。
8. **医院名提取**：“帮我挂协和医院的号”能正确提取“协和医院”；追问时只答“协和”“省中医”也能接受，不会陷入死循环。
9. **科室误判**：“担心”“开心”不再被识别成心内科。
10. **主动复诊提醒永远不触发**：演示数据改为“27 天前就诊、30 天后复诊”，打开就能看到；每天最多播报一次，前后台切换不再重复。
11. **提醒时间不合理**：前一晚提醒固定在 20:00，下午的号不会半夜提醒；删掉“在手表上点一下”这类不存在的操作；导航结果进入提醒链，快到医院时直接打开院内引导。
12. **天气不跟位置和日期走**：按定位查当地天气，并查就诊当天的预报；超出预报范围时如实说明。
13. **桌面卡片停在第 1 步**：卡片每次刷新按当前时间计算下一步；点卡片直达对应页面。

### 次要问题与合规

14. 本机数据损坏时不再导致启动崩溃。
15. `deviceTypes` 去掉 wearable；手表提醒通过系统通知同步。
16. 页面改用 UIContext 提供的路由、提示框和上下文接口，替换弃用 API。
17. 三个技能脚本改为自包含，不再引用 `src/main/ets`，可以直接上传到小艺开放平台。
18. 网关新增访问令牌和限流；`.env.example` 改为 DeepSeek，模型名更新为 `deepseek-flash`（`deepseek-chat` 已于 2026-07-24 停用）。

---

## 五、新增与优化

- **陪诊安排按阶段推进**：草稿 → 待官方确认 → 已确认，每个阶段只给出当下该做的按钮；新方案替换已有安排前会提示；取消安排时同步关闭提醒。
- **院内引导页**：分步大字卡片，每步语音播报，支持上一步、再听一遍、下一步、我到了；引导期间屏幕常亮。
- **“我的”页**：档案（称呼、年龄、出发地、常去医院、紧急联系人）、病历列表与删除、手动添加病历、演示工具、清除全部数据、网关连接状态。
- **看完病闭环**：就诊 2 小时后首页询问复诊间隔（2 周 / 1 个月 / 3 个月 / 不用 / 拍处方单 / 没去成）。
- **拍处方单**：系统图片选择器可以直接拍照；识别后先让本人核对再保存；识别失败时说清原因（拍糊了、不是处方单、设备不支持）并提供手动录入。
- **对话能力**：行程问答（几点出发、带什么、诊室在哪、天气）、急症引导 120、一键打给家人、查报告引导。
- **适老化交互**：追问时给出可点的候选；对话气泡点一下重听；语音边说边出字；处理中有进度提示；播报放慢语速。
- **数据可信**：所有数据标注来源（演示 / 实时 / 估算），推荐方案与已挂号严格区分。
- **真实数据接入**：医院名经高德检索成真实医院全称和坐标；天气用就诊当天预报；路线按医院坐标计算；按城市匹配官方挂号渠道。
- **启动与跳转**：App 单实例启动，点通知或卡片时复用已有页面并跳转到目标页。
- **网关**：DeepSeek JSON 模式、默认关闭思考模式、空内容或非法 JSON 自动重试一次；高德天气、路线、医院检索；访问令牌、限流、错误信息脱敏；测试从 5 项增加到 39 项。

---

## 六、配置变化

- `entry/src/main/ets/config/BackendConfig.ets`：新增 `APP_TOKEN`，与网关 `APP_ACCESS_TOKEN` 一致；网关没设就留空。
- `backend/.env`：字段有增加，请对照新的 `.env.example` 重新生成。`LLM_MODEL` 用 `deepseek-flash`，`LLM_THINKING=auto` 会对 DeepSeek 自动关闭思考模式。
- `module.json5`：`deviceTypes` 改为 phone、tablet；`launchType` 改为 singleton；新增启动页图标 `startIcon`；移除两项未使用的权限；travel-plan、hospital-nav、care-reminder 三个技能版本升到 1.0.1（小艺开放平台上需要重新上传这三个技能），medical-assist 保持 1.0.3 不变。
- `main_pages.json`：新增 `pages/NavGuidePage`、`pages/ProfilePage`。
- travel-plan 技能脚本顶部新增 `GATEWAY_BASE_URL`、`GATEWAY_APP_TOKEN`，不填时返回标注“估算”的车程。

---

## 七、已知限制

- 号源、医生、诊室、院内路线仍是演示数据（没有医院接口），页面已明确标注。
- 挂号和取消挂号需要本人在官方渠道完成。
- 手表提醒依赖系统通知同步，不是手表端的独立应用。
- 网关限流是进程内实现，适合单实例部署。
- 语音识别与播报、文字识别、代理提醒、定位需要在真机上验证。
