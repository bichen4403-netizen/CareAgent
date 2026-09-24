# 联调与验收指南

> 本文件原为“第一阶段：可信闭环”说明，v1.1 起更新为团队联调与验收指南。功能说明见 [README.md](README.md)，改动清单见 [CHANGELOG.md](CHANGELOG.md)。

## 已完成

**第一阶段：可信闭环**

- 多轮槽位补全：追问时不会丢失上一轮的医院、科室、日期，10 分钟后自动过期；支持“算了 / 不用了”取消。
- Agent 结果携带数据来源、核验状态和更新时间，页面明确标识演示或估算数据。
- 同一异常只触发一次重规划；部分失败时不再播报“都安排好了”。
- 大模型、天气、路线都经 FastAPI 网关调用，密钥只保存在服务端 `.env`。
- 发给大模型的内容不含姓名、住址和医生姓名。

**第二阶段：v1.1 完整闭环**

- 方案持久化与分阶段确认、系统代理提醒可撤销且点击直达、院内引导页、“我的”页、看完病闭环、拍处方单识别。
- 语音识别 / 播报、权限申请、日期与医院名理解等问题全部修复（详见 CHANGELOG）。
- 网关支持 DeepSeek `deepseek-flash`、高德医院检索与就诊日预报、访问令牌与限流；测试 39 项。

## 本地联调

1. 进入 `backend`，复制 `.env.example` 为 `.env`，填写 `LLM_API_KEY`（DeepSeek）和 `AMAP_API_KEY`（高德「Web服务」Key），`LLM_MODEL` 保持 `deepseek-flash`。
2. 安装依赖并运行：

```bash
python -m venv .venv
# Windows PowerShell
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

3. 浏览器打开 `http://127.0.0.1:8000/health`，确认 `llm_configured`、`amap_configured` 都是 `true`。
4. 修改 `entry/src/main/ets/config/BackendConfig.ets`：

```ts
static readonly BASE_URL: string = 'http://10.0.2.2:8000';  // 模拟器；真机用电脑局域网 IP
static readonly APP_TOKEN: string = '';                      // 与 .env 的 APP_ACCESS_TOKEN 一致
```

正式环境必须使用 HTTPS。

## 建议的 Git 流程

在 DevEco Studio 的 Terminal 中执行：

```bash
git switch main
git pull --ff-only origin main
git switch -c feat/v1.1-full-loop
git status
git add .
git commit -m "feat: v1.1 full care loop"
git push -u origin feat/v1.1-full-loop
```

随后在 GitHub 创建 Pull Request。不要提交 `backend/.env`、`.venv`、`local.properties`、构建目录或任何 API Key（已写入 `.gitignore`）。

## 验收场景

1. 说“我想去看病”，系统一次只追问一项，并给出可点的候选。
2. 追问日期时只回答“下周三”，之前说过的医院和科室不丢。
3. 说“昨天去市第一人民医院看心内科”，系统提示日期已过去并请求改期。
4. 未配置网关时首页显示“离线演示模式”，天气、车程标注演示或估算。
5. 配置网关后首页显示“已连接大模型”，天气、车程标注实时。
6. 打开“模拟医生临时停诊”和“模拟就诊日暴雨”后安排，两种异常各重规划一次并播报原因，出发时间提前。
7. 任一 Agent 失败时，最终播报“只完成了部分安排”。
8. 确认挂号并开启提醒后，从后台划掉 App 再打开，陪诊安排仍在；提醒到点弹出，点提醒进入对应页面。
9. 说“我胸口疼得厉害”，立即引导拨打 120。
10. 拍处方单或手动录入病历，核对保存后，复诊到期前 3 天首页出现提醒卡片。
