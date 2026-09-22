# CareAgent FastAPI 网关

该服务保存大模型和地图密钥，鸿蒙客户端只访问本项目网关。

## 本地启动

```bash
cd backend
python -m venv .venv
# Windows PowerShell: .venv\Scripts\Activate.ps1
# macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
copy .env.example .env  # Windows；macOS/Linux 使用 cp
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

打开 `http://127.0.0.1:8000/docs` 可调试接口。

在鸿蒙端修改 `entry/src/main/ets/config/BackendConfig.ets`：

- DevEco 模拟器通常使用 `http://10.0.2.2:8000`
- 真机使用电脑局域网 IP，例如 `http://192.168.1.8:8000`
- 正式环境必须使用 HTTPS

## 测试

```bash
cd backend
pytest -q
```

未配置供应商密钥时，天气和路线只返回带 `FALLBACK` 标识的演示数据；大模型接口返回 503，鸿蒙端再执行本地规则兜底。生产环境将 `ALLOW_DEMO_FALLBACK=false`。
