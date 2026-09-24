"""智护同行 · 网关请求 / 响应模型（字段名与鸿蒙端 services/*.ets 一一对应）"""
from typing import Literal

from pydantic import AliasChoices, BaseModel, Field, model_validator

DataSource = Literal["REALTIME_API", "FALLBACK"]
TrafficLevel = Literal["畅通", "缓行", "拥堵", "未知"]

MAX_TOTAL_PROMPT_CHARS = 60_000


# ==================== 大模型 ====================

class LLMMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str = Field(min_length=1, max_length=20_000)


class LLMChatRequest(BaseModel):
    messages: list[LLMMessage] = Field(min_length=1, max_length=30)
    temperature: float = Field(default=0.2, ge=0, le=2)
    max_tokens: int | None = Field(default=None, ge=1, le=8192)
    # true：网关按 JSON 模式调用模型，并保证返回内容是合法 JSON 对象
    json_mode: bool = False
    # 网关只支持非流式输出
    stream: bool = False
    # 兼容字段：实际使用的模型由网关 .env 的 LLM_MODEL 决定，客户端不能随意切换（控制费用）
    model: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def _check(self) -> "LLMChatRequest":
        if self.stream:
            raise ValueError("网关只支持非流式输出，请设置 stream=false")
        total = sum(len(m.content) for m in self.messages)
        if total > MAX_TOTAL_PROMPT_CHARS:
            raise ValueError(f"提示词总长度 {total} 超过上限 {MAX_TOTAL_PROMPT_CHARS}")
        return self


# ==================== 出行路线 ====================

class RouteRequest(BaseModel):
    origin_lng: float = Field(ge=-180, le=180)
    origin_lat: float = Field(ge=-90, le=90)
    # 兼容旧字段名 destination_address
    dest_address: str = Field(min_length=2, max_length=200,
                              validation_alias=AliasChoices("dest_address", "destination_address"))
    dest_lng: float | None = Field(default=None, ge=-180, le=180)
    dest_lat: float | None = Field(default=None, ge=-90, le=90)
    mode: Literal["driving"] = "driving"

    @model_validator(mode="after")
    def _check(self) -> "RouteRequest":
        if self.origin_lng == 0 and self.origin_lat == 0:
            raise ValueError("起点坐标无效")
        if (self.dest_lng is None) != (self.dest_lat is None):
            raise ValueError("dest_lng 与 dest_lat 需要同时提供")
        # 客户端用 0 表示“未知坐标”
        if self.dest_lng == 0 and self.dest_lat == 0:
            self.dest_lng = None
            self.dest_lat = None
        return self

    def dest_point(self) -> tuple[float, float] | None:
        if self.dest_lng is None or self.dest_lat is None:
            return None
        return self.dest_lng, self.dest_lat


class RouteResponse(BaseModel):
    duration_min: int = Field(gt=0)
    distance_km: float = Field(gt=0)
    traffic_level: TrafficLevel
    data_source: DataSource
    provider: str
    updated_at: int
    dest_lng: float | None = None
    dest_lat: float | None = None
    dest_name: str | None = None
    note: str | None = None


# ==================== 天气 ====================

class WeatherResponse(BaseModel):
    weather: str
    temperature: str = ""
    city: str = ""
    date: str | None = None
    is_forecast: bool = False
    data_source: DataSource
    provider: str
    updated_at: int
    note: str | None = None


# ==================== 医院检索 ====================

class HospitalBrief(BaseModel):
    name: str
    address: str
    distance_km: float | None = None


class HospitalResponse(BaseModel):
    name: str
    address: str
    lng: float
    lat: float
    city: str
    district: str = ""
    distance_km: float | None = None
    data_source: DataSource
    provider: str
    # 同名 / 相近医院，便于以后在客户端让老人二选一
    alternatives: list[HospitalBrief] = Field(default_factory=list)
