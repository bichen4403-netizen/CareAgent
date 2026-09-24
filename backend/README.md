# 智护同行 · FastAPI 网关

鸿蒙 App 和小艺技能脚本只访问这个网关；DeepSeek 与高德的密钥只保存在服务端 `.env`，客户端不保存任何第三方密钥。

## 本地启动

需要 Python 3.10 及以上。

```bash
cd backend
python -m venv .venv
# Windows PowerShell: .venv\Scripts\Activate.ps1
# macOS / Linux:      source .venv/bin/activate
pip install -r requirements.txt
copy .env.example .env      # Windows；macOS / Linux 用 cp
# 编辑 .env，至少填 LLM_API_KEY（DeepSeek）和 AMAP_API_KEY（高德「Web服务」Key）
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

启动后打开 `http://127.0.0.1:8000/health` 可以看到密钥是否配置、当前模型名；`http://127.0.0.1:8000/docs` 可以直接调试所有接口。

然后修改鸿蒙端 `entry/src/main/ets/config/BackendConfig.ets`：

- `BASE_URL`：DevEco 模拟器通常填 `http://10.0.2.2:8000`；真机填电脑的局域网地址，如 `http://192.168.1.8:8000`（手机和电脑连同一个 Wi-Fi，电脑防火墙放行 8000 端口）；正式环境必须用 HTTPS 域名。
- `APP_TOKEN`：与 `.env` 里的 `APP_ACCESS_TOKEN` 相同；网关没设就留空。

## 接口

| 接口 | 用途 | 关键字段 |
| --- | --- | --- |
| `GET /health` | 健康检查（不需要令牌） | `llm_configured`、`amap_configured`、`llm_model` |
| `POST /v1/llm/chat` | 意图理解、处方单字段抽取 | 入参 `messages`、`json_mode`；返回 OpenAI 风格 `choices[0].message.content` |
| `GET /v1/weather` | 实况天气或就诊日预报 | `lng`+`lat` 或 `city_code`，可选 `date=YYYY-MM-DD`；返回 `weather`、`city`、`is_forecast` |
| `POST /v1/travel/route` | 驾车路线与路况 | `origin_lng/lat`、`dest_address`，可选 `dest_lng/lat`；返回 `duration_min`、`distance_km`、`traffic_level` |
| `GET /v1/hospital/search` | 按老人说的医院名找真实医院 | `keyword`，可选 `lng/lat`；返回全称、地址、坐标、`alternatives` |

说明：

- **大模型**：模型由 `.env` 的 `LLM_MODEL` 决定，客户端不能自选（控制费用）。`json_mode=true` 时网关设置 `response_format=json_object`，提示词里没有 “json” 字样会自动补一句，并校验返回的是合法 JSON 对象；空内容或非法 JSON 会在时限内重试一次，仍失败返回 502，客户端随即退回离线规则并在界面上标注。
- **思考模式**：DeepSeek 默认开启思考模式，意图理解这类短任务会明显变慢、超过客户端 15 秒超时。`LLM_THINKING=auto` 时对 DeepSeek 自动发送 `thinking: disabled`，换成其他 OpenAI 兼容服务商时不发送该参数。
- **天气**：按坐标逆地理编码拿到区县编码再查高德天气。就诊日在今天起 4 天内返回当天预报（白天天气 + 温度区间），更远的日期如实返回 `暂无预报`，App 会改为提醒“出门前看一眼天气”。
- **医院检索**：先在用户周边 50 公里内检索，按“名称匹配 + 综合 / 专科医院优先 + 距离”打分，排除宠物医院、药店，并压低“东门”“停车场”这类附属点位；周边找不到再全国检索（异地就医）。
- **路线**：已知医院坐标时直接算路；只有名称或地址时，门牌地址先地理编码，医院名先走医院检索。路况按平均车速粗分为畅通 / 缓行 / 拥堵。

## 兜底与报错

| 情况 | `ALLOW_DEMO_FALLBACK=true`（演示） | `false`（正式） |
| --- | --- | --- |
| 未配置高德 Key 或高德调用失败 | 天气返回 `小雨`、路线返回估算或演示车程，`data_source=FALLBACK` 并在 `note` 写明原因 | 503 |
| 医院检索没有高德 Key | 503（不编造医院） | 503 |
| 未配置 `LLM_API_KEY` | 503，客户端使用离线规则理解 | 503 |
| 模型报错 / 超时 | 502 / 504，`detail` 里写明上游原因（如余额不足、模型名不受支持） | 同左 |

错误信息经过脱敏：高德 Key 放在请求 URL 里，网关不会把原始异常文本（含 URL）返回给客户端或写进日志。

## 访问控制

- `APP_ACCESS_TOKEN` 非空时，`/v1/*` 需要请求头 `X-App-Token`。它只能防止网关地址被随手滥用，不等于用户鉴权。
- 进程内限流：每个 IP 每分钟 `RATE_LIMIT_PER_MIN` 次（天气 / 路线 / 医院），大模型单独 `LLM_RATE_LIMIT_PER_MIN` 次，超出返回 429。部署在反向代理后面时设 `TRUST_PROXY_HEADERS=true`。多实例部署请改用 Nginx 或 Redis 限流。

## 测试

```bash
cd backend
pytest -q
```

测试不会访问任何外部服务：默认清空所有密钥，需要验证真实调用路径的用例用 `httpx.MockTransport` 模拟 DeepSeek 与高德的返回，覆盖 JSON 模式请求格式、思考模式开关、空内容重试、上游报错映射、天气预报取日、直辖市城市名、医院打分排序、地址 / 医院名两种路线解析、访问令牌、限流，以及密钥不外泄。

## Docker 部署

```bash
cd backend
docker build -t careagent-gateway .
docker run -d --name careagent-gateway --env-file .env -p 8000:8000 careagent-gateway
```

正式对外提供服务时，请在前面加 HTTPS（如 Nginx + 证书），并把 `ALLOW_DEMO_FALLBACK` 设为 `false`。

## 常见问题

- **App 一直显示“离线规则理解”**：先看 `/health` 的 `llm_configured`；再看网关日志里有没有 `llm upstream error`。填了已停用的旧模型名 `deepseek-chat` 会看到上游 HTTP 400（模型名不受支持），改成 `deepseek-flash`。
- **真机连不上网关**：确认 `BASE_URL` 用的是电脑局域网 IP 而不是 `127.0.0.1`，手机与电脑在同一网络，电脑防火墙放行端口。
- **返回 401**：App 的 `BackendConfig.APP_TOKEN`（或技能脚本的 `GATEWAY_APP_TOKEN`）与 `.env` 的 `APP_ACCESS_TOKEN` 不一致。
- **天气总是“小雨”**：`data_source` 为 `FALLBACK` 表示高德没配好或调用失败，`note` 字段里有原因（如 `INVALID_USER_KEY` 表示 Key 类型或值不对）。
