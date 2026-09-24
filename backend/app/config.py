"""
智护同行 · 网关配置

所有第三方密钥（DeepSeek、高德）只放在服务端 .env 中，鸿蒙客户端永远不保存密钥。
配置在进程启动时读取一次；测试里用 dataclasses.replace 替换 config.settings。
"""
import os
from dataclasses import dataclass

from dotenv import load_dotenv

# 无论谁先 import，都保证 .env 已加载（已存在的环境变量优先，不会被 .env 覆盖）
load_dotenv()

DEFAULT_LLM_BASE_URL = "https://api.deepseek.com"
# DeepSeek 旧模型名 deepseek-chat / deepseek-reasoner 已于 2026-07-24 停用；
# deepseek-flash 指向当前最新的 Flash 模型，需要更强效果可改为 deepseek-v4-pro。
DEFAULT_LLM_MODEL = "deepseek-flash"


def _as_bool(value: str | None, default: bool) -> bool:
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _as_int(value: str | None, default: int, low: int, high: int) -> int:
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(low, min(high, number))


def _as_float(value: str | None, default: float, low: float, high: float) -> float:
    try:
        number = float(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(low, min(high, number))


@dataclass(frozen=True)
class Settings:
    # ---- 大模型（OpenAI 兼容接口，默认 DeepSeek）----
    llm_base_url: str
    llm_api_key: str
    llm_model: str
    llm_thinking: str          # auto | disabled | enabled | omit
    llm_max_tokens: int        # 默认值兼上限
    llm_timeout_s: float       # 必须小于客户端 15 秒读超时
    # ---- 高德 Web 服务 ----
    amap_api_key: str
    # ---- 访问控制 ----
    app_access_token: str      # 非空时要求请求头 X-App-Token 一致
    rate_limit_per_min: int    # 天气 / 路线 / 医院检索，每个 IP 每分钟；0 表示不限
    llm_rate_limit_per_min: int
    trust_proxy_headers: bool  # 部署在反向代理后面时按 X-Forwarded-For 识别客户端
    # ---- 其他 ----
    allow_demo_fallback: bool
    cors_origins: str

    @staticmethod
    def from_env() -> "Settings":
        thinking = os.getenv("LLM_THINKING", "auto").strip().lower()
        if thinking not in {"auto", "disabled", "enabled", "omit"}:
            thinking = "auto"
        return Settings(
            llm_base_url=os.getenv("LLM_BASE_URL", DEFAULT_LLM_BASE_URL).strip() or DEFAULT_LLM_BASE_URL,
            llm_api_key=os.getenv("LLM_API_KEY", "").strip(),
            llm_model=os.getenv("LLM_MODEL", DEFAULT_LLM_MODEL).strip() or DEFAULT_LLM_MODEL,
            llm_thinking=thinking,
            llm_max_tokens=_as_int(os.getenv("LLM_MAX_TOKENS"), 1024, 64, 8192),
            llm_timeout_s=_as_float(os.getenv("LLM_TIMEOUT_S"), 12.0, 3.0, 60.0),
            amap_api_key=os.getenv("AMAP_API_KEY", "").strip(),
            app_access_token=os.getenv("APP_ACCESS_TOKEN", "").strip(),
            rate_limit_per_min=_as_int(os.getenv("RATE_LIMIT_PER_MIN"), 60, 0, 100_000),
            llm_rate_limit_per_min=_as_int(os.getenv("LLM_RATE_LIMIT_PER_MIN"), 20, 0, 100_000),
            trust_proxy_headers=_as_bool(os.getenv("TRUST_PROXY_HEADERS"), False),
            allow_demo_fallback=_as_bool(os.getenv("ALLOW_DEMO_FALLBACK"), True),
            cors_origins=os.getenv("CORS_ORIGINS", "*"),
        )

    @property
    def llm_configured(self) -> bool:
        return len(self.llm_api_key) > 0

    @property
    def amap_configured(self) -> bool:
        return len(self.amap_api_key) > 0

    @property
    def is_deepseek(self) -> bool:
        return "deepseek.com" in self.llm_base_url.lower()

    def thinking_param(self) -> dict | None:
        """DeepSeek 默认开启思考模式，会明显拖慢响应；意图理解这类短任务应关闭。
        其他 OpenAI 兼容服务商可能不认识 thinking 字段，auto 模式下不发送。"""
        mode = self.llm_thinking
        if mode == "auto":
            mode = "disabled" if self.is_deepseek else "omit"
        if mode in {"disabled", "enabled"}:
            return {"type": mode}
        return None


settings = Settings.from_env()
