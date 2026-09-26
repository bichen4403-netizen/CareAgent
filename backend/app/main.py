"""
智护同行 · FastAPI 网关

鸿蒙 App 只访问本网关；DeepSeek 与高德的密钥只保存在服务端 .env。

接口一览（字段与客户端 services/*.ets 一一对应）：
  GET  /health                 健康检查（无需令牌）
  POST /v1/llm/chat            大模型对话（OpenAI 风格返回 choices[0].message.content）
  GET  /v1/weather             天气：lng/lat 或 city_code，可选 date=YYYY-MM-DD 查就诊日预报
  POST /v1/travel/route        驾车路线：origin_lng/lat + dest_address，可选 dest_lng/lat
  GET  /v1/hospital/search     医院检索：keyword，可选 lng/lat（按附近优先）
"""
from __future__ import annotations

import hmac
import logging
import time
from collections import deque
from collections.abc import Awaitable, Callable
from datetime import date

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware

from . import config, providers
from .models import HospitalResponse, LLMChatRequest, RouteRequest, RouteResponse, WeatherResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("careagent")
# httpx 的 INFO 日志会把完整请求 URL 写入控制台；高德 Web 服务 Key 位于查询参数中，
# 因此不得输出该级别日志，避免密钥被终端记录或截图带出。
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

VERSION = "1.1.0"


class RateLimiter:
    """进程内滑动窗口限流。单实例部署够用；多实例部署请改用 Nginx / Redis 限流。"""

    def __init__(self) -> None:
        self._hits: dict[str, deque[float]] = {}

    def hit(self, key: str, limit: int, window_s: float = 60.0) -> float | None:
        """记录一次请求；超限时返回还需等待的秒数，否则返回 None"""
        now = time.monotonic()
        queue = self._hits.get(key)
        if queue is None:
            if len(self._hits) > 10_000:
                self._evict(now, window_s)
            queue = deque()
            self._hits[key] = queue
        while queue and now - queue[0] >= window_s:
            queue.popleft()
        if len(queue) >= limit:
            return max(0.0, window_s - (now - queue[0]))
        queue.append(now)
        return None

    def _evict(self, now: float, window_s: float) -> None:
        stale = [key for key, queue in self._hits.items() if not queue or now - queue[-1] >= window_s]
        for key in stale:
            del self._hits[key]

    def reset(self) -> None:
        self._hits.clear()


limiter = RateLimiter()

app = FastAPI(title="智护同行 Gateway", version=VERSION,
              description="智护同行多智能体陪诊系统的服务端网关：DeepSeek 大模型 + 高德天气 / 路线 / 医院检索")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[item.strip() for item in config.settings.cors_origins.split(",") if item.strip()],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "Authorization", "X-App-Token"],
)


def client_ip(request: Request) -> str:
    if config.settings.trust_proxy_headers:
        forwarded = request.headers.get("x-forwarded-for", "")
        if forwarded.strip():
            return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


async def require_app_token(x_app_token: str | None = Header(default=None)) -> None:
    """APP_ACCESS_TOKEN 非空时校验请求头 X-App-Token。只防网关地址被随手滥用，不是用户鉴权。"""
    expected = config.settings.app_access_token
    if not expected:
        return
    if x_app_token is None or not hmac.compare_digest(x_app_token.encode("utf-8"), expected.encode("utf-8")):
        raise HTTPException(status_code=401,
                            detail="访问令牌无效：请求头 X-App-Token 需与网关 APP_ACCESS_TOKEN 一致")


def rate_limit(bucket: str) -> Callable[[Request], Awaitable[None]]:
    async def dependency(request: Request) -> None:
        s = config.settings
        limit = s.llm_rate_limit_per_min if bucket == "llm" else s.rate_limit_per_min
        if limit <= 0:
            return
        wait = limiter.hit(f"{bucket}:{client_ip(request)}", limit)
        if wait is not None:
            raise HTTPException(status_code=429, detail="请求太频繁，请稍后再试",
                                headers={"Retry-After": str(int(wait) + 1)})
    return dependency


def _valid_point(lng: float | None, lat: float | None) -> bool:
    return lng is not None and lat is not None and not (lng == 0 and lat == 0)


@app.get("/health")
async def health() -> dict[str, object]:
    s = config.settings
    return {
        "status": "ok",
        "service": "careagent-gateway",
        "version": VERSION,
        "llm_configured": s.llm_configured,
        "llm_model": s.llm_model,
        "amap_configured": s.amap_configured,
        "demo_fallback": s.allow_demo_fallback,
        "token_required": len(s.app_access_token) > 0,
    }


router = APIRouter(prefix="/v1", dependencies=[Depends(require_app_token)])


@router.post("/llm/chat", dependencies=[Depends(rate_limit("llm"))])
async def llm_chat(payload: LLMChatRequest) -> dict[str, object]:
    try:
        return await providers.chat_completion(payload)
    except providers.ProviderUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except providers.UpstreamError as exc:
        logger.warning("llm upstream error: %s", exc)
        raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc


@router.get("/weather", response_model=WeatherResponse, dependencies=[Depends(rate_limit("default"))])
async def weather(
    lng: float | None = Query(default=None, ge=-180, le=180),
    lat: float | None = Query(default=None, ge=-90, le=90),
    city_code: str | None = Query(default=None, pattern=r"^\d{6}$"),
    visit_date: str | None = Query(default=None, alias="date", pattern=r"^\d{4}-\d{2}-\d{2}$"),
) -> WeatherResponse:
    has_point = _valid_point(lng, lat)
    if not has_point and city_code is None:
        raise HTTPException(status_code=422, detail="需要提供 lng/lat 坐标或 6 位行政区编码 city_code")
    target: date | None = None
    if visit_date is not None:
        try:
            target = date.fromisoformat(visit_date)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail="date 格式应为 YYYY-MM-DD") from exc
        if target < providers.today_cn():
            raise HTTPException(status_code=422, detail="date 不能早于今天")
    try:
        if city_code is not None:
            return await providers.get_weather(None, None, city_code, target)
        return await providers.get_weather(lng, lat, None, target)
    except providers.ProviderUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@router.post("/travel/route", response_model=RouteResponse, dependencies=[Depends(rate_limit("default"))])
async def travel_route(payload: RouteRequest) -> RouteResponse:
    try:
        return await providers.get_route(payload)
    except providers.ProviderUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@router.get("/hospital/search", response_model=HospitalResponse, dependencies=[Depends(rate_limit("default"))])
async def hospital_search(
    keyword: str = Query(min_length=2, max_length=50),
    lng: float | None = Query(default=None, ge=-180, le=180),
    lat: float | None = Query(default=None, ge=-90, le=90),
) -> HospitalResponse:
    has_point = _valid_point(lng, lat)
    try:
        return await providers.search_hospital(keyword, lng if has_point else None, lat if has_point else None)
    except providers.NotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except providers.ProviderUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


app.include_router(router)
