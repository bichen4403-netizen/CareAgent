import time
from typing import Any

import httpx

from .config import settings
from .models import LLMChatRequest, RouteRequest, RouteResponse, WeatherResponse


class ProviderUnavailable(RuntimeError):
    pass


async def chat_completion(payload: LLMChatRequest) -> dict[str, Any]:
    if not settings.llm_api_key:
        raise ProviderUnavailable("LLM_API_KEY is not configured")
    body = payload.model_dump(exclude_none=True)
    body["model"] = payload.model or settings.llm_model
    body["stream"] = False
    headers = {"Authorization": f"Bearer {settings.llm_api_key}"}
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            f"{settings.llm_base_url.rstrip('/')}/chat/completions",
            json=body,
            headers=headers,
        )
        response.raise_for_status()
        return response.json()


async def get_weather(city_code: str) -> WeatherResponse:
    if not settings.amap_api_key:
        return _fallback_weather("AMAP_API_KEY is not configured")
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(
                "https://restapi.amap.com/v3/weather/weatherInfo",
                params={"city": city_code, "key": settings.amap_api_key, "extensions": "base"},
            )
            response.raise_for_status()
            body = response.json()
        lives = body.get("lives") or []
        if not lives:
            raise ProviderUnavailable("AMap returned no weather data")
        return WeatherResponse(
            weather=lives[0]["weather"], data_source="REALTIME_API",
            provider="amap", updated_at=int(time.time() * 1000),
        )
    except (httpx.HTTPError, KeyError, ValueError, ProviderUnavailable) as exc:
        return _fallback_weather(str(exc))


async def get_route(request: RouteRequest) -> RouteResponse:
    if not settings.amap_api_key:
        return _fallback_route("AMAP_API_KEY is not configured")
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            geocode = await client.get(
                "https://restapi.amap.com/v3/geocode/geo",
                params={"address": request.destination_address, "key": settings.amap_api_key},
            )
            geocode.raise_for_status()
            points = geocode.json().get("geocodes") or []
            if not points:
                raise ProviderUnavailable("destination geocoding returned no result")
            destination = points[0]["location"]
            route = await client.get(
                "https://restapi.amap.com/v3/direction/driving",
                params={
                    "origin": f"{request.origin_lng},{request.origin_lat}",
                    "destination": destination,
                    "strategy": 10,
                    "extensions": "base",
                    "key": settings.amap_api_key,
                },
            )
            route.raise_for_status()
        paths = route.json().get("route", {}).get("paths") or []
        if not paths:
            raise ProviderUnavailable("AMap returned no route")
        duration_sec = int(paths[0]["duration"])
        distance_m = int(paths[0]["distance"])
        return RouteResponse(
            duration_min=max(1, round(duration_sec / 60)),
            distance_km=max(0.1, round(distance_m / 100) / 10),
            traffic_level=_traffic_level(duration_sec, distance_m),
            data_source="REALTIME_API", provider="amap",
            updated_at=int(time.time() * 1000),
        )
    except (httpx.HTTPError, KeyError, TypeError, ValueError, ProviderUnavailable) as exc:
        return _fallback_route(str(exc))


def _traffic_level(duration_sec: int, distance_m: int) -> str:
    if duration_sec <= 0:
        return "畅通"
    speed_kmh = distance_m / 1000 / (duration_sec / 3600)
    if speed_kmh >= 30:
        return "畅通"
    if speed_kmh >= 15:
        return "缓行"
    return "拥堵"


def _fallback_weather(reason: str) -> WeatherResponse:
    if not settings.allow_demo_fallback:
        raise ProviderUnavailable(reason)
    return WeatherResponse(
        weather="小雨", data_source="FALLBACK", provider="offline-demo",
        updated_at=int(time.time() * 1000),
    )


def _fallback_route(reason: str) -> RouteResponse:
    if not settings.allow_demo_fallback:
        raise ProviderUnavailable(reason)
    return RouteResponse(
        duration_min=28, distance_km=8.6, traffic_level="缓行",
        data_source="FALLBACK", provider="offline-demo",
        updated_at=int(time.time() * 1000),
    )
