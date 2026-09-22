import os
from dataclasses import dataclass


def _as_bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    llm_base_url: str = os.getenv("LLM_BASE_URL", "https://api.openai.com/v1")
    llm_api_key: str = os.getenv("LLM_API_KEY", "")
    llm_model: str = os.getenv("LLM_MODEL", "gpt-4.1-mini")
    amap_api_key: str = os.getenv("AMAP_API_KEY", "")
    allow_demo_fallback: bool = _as_bool(os.getenv("ALLOW_DEMO_FALLBACK", "true"))
    cors_origins: str = os.getenv("CORS_ORIGINS", "*")


settings = Settings()
