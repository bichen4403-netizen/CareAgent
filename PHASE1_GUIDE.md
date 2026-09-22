# 第一阶段：可信闭环

## 已完成

- 多轮槽位补全：上一轮医院、科室、日期不会在追问时丢失，10 分钟后自动过期。
- 支持“取消 / 重新来 / 不用了”清空待补全会话。
- Agent 结果携带数据来源、核验状态和更新时间，页面明确标识演示/降级数据。
- 同一异常只触发一次重规划，部分失败不再播报“都安排好了”。
- 新增 FastAPI 网关：真实大模型、天气和路线都从服务端调用。
- 后端密钥仅保存在 `.env`，`.env` 已加入 `.gitignore`。
- 新增 5 个 API 测试及 GitHub Actions。
- 发送给大模型的上下文不再包含姓名、精确住址和医生姓名。

## 本地联调

1. 进入 `backend`，复制 `.env.example` 为 `.env`。
2. 填写 `LLM_API_KEY`、`LLM_BASE_URL`、`LLM_MODEL` 和 `AMAP_API_KEY`。
3. 安装依赖并运行：

```bash
python -m venv .venv
# Windows PowerShell
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

4. 修改 `entry/src/main/ets/config/BackendConfig.ets`：

```ts
static readonly BASE_URL: string = 'http://10.0.2.2:8000';
```

模拟器通常使用 `10.0.2.2`，真机使用电脑局域网 IP。正式环境必须使用 HTTPS。

## 建议的 Git 流程

在 DevEco Studio 的 Terminal 中执行：

```bash
git switch main
git pull --ff-only origin main
git switch -c feat/credible-loop
git status
git add .
git commit -m "feat: build phase-one credible care loop"
git push -u origin feat/credible-loop
```

随后在 GitHub 创建 Pull Request。不要提交 `backend/.env`、`.venv`、`local.properties`、构建目录或 API Key。

## 验收场景

1. 用户说“我要去医院复查”，系统逐项追问缺失信息。
2. 用户只回答“下周三”，系统保留上一轮医院和科室。
3. 未配置网关时，页面明确显示演示或降级数据。
4. 配置网关后，出行 Agent 显示实时接口及核验状态。
5. 暴雨只触发一次重规划。
6. 任一 Agent 失败时，最终播报“只完成了部分安排”。
