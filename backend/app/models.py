from typing import Literal

from pydantic import BaseModel, Field


class LLMMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str = Field(min_length=1, max_length=20_000)


class LLMChatRequest(BaseModel):
    messages: list[LLMMessage] = Field(min_length=1, max_length=30)
    model: str | None = None
    temperature: float = Field(default=0.2, ge=0, le=1)
    stream: bool = False


class RouteRequest(BaseModel):
    origin_lng: float = Field(ge=-180, le=180)
    origin_lat: float = Field(ge=-90, le=90)
    destination_address: str = Field(min_length=2, max_length=200)


class RouteResponse(BaseModel):
    duration_min: int = Field(gt=0)
    distance_km: float = Field(gt=0)
    traffic_level: Literal["畅通", "缓行", "拥堵"]
    data_source: Literal["REALTIME_API", "FALLBACK"]
    provider: str
    updated_at: int


class WeatherResponse(BaseModel):
    weather: str
    data_source: Literal["REALTIME_API", "FALLBACK"]
    provider: str
    updated_at: int
