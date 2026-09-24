"""
智护同行 · 第三方服务适配

- 大模型：OpenAI 兼容 /chat/completions（默认 DeepSeek）。JSON 模式、关闭思考模式、
  空内容 / 非法 JSON 时在时限内重试一次，失败如实返回 502/504，由客户端退回离线规则。
- 高德 Web 服务：逆地理编码 → 天气（实况 / 4 天预报）、POI 医院检索、驾车路线。
- 未配置密钥或调用失败：ALLOW_DEMO_FALLBACK=true 时返回带 FALLBACK 标识的演示 / 估算数据，
  否则如实报错（503）。

安全：httpx 异常的字符串里带完整请求 URL（高德的 key 在查询参数里），
这里绝不把 str(exc) 返回给客户端或写进日志，统一经 describe_error 脱敏。
"""
from __future__ import annotations

import json
import logging
import math
import re
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any

import httpx

from . import config
from .models import (HospitalBrief, HospitalResponse, LLMChatRequest, RouteRequest, RouteResponse,
                     WeatherResponse)

logger = logging.getLogger("careagent.providers")

AMAP_BASE = "https://restapi.amap.com"
CN_TZ = timezone(timedelta(hours=8))
FORECAST_DAYS = 3            # 高德预报覆盖今天 + 未来 3 天
DEMO_WEATHER = "小雨"
NO_FORECAST = "暂无预报"      # 客户端据此改用“出门前看天气”的说法
HOSPITAL_TYPES = "090000"    # 高德 POI 大类：医疗保健服务，再按子类打分筛选
# 单次高德请求的超时：要明显小于客户端 BackendClient 的 8 秒读超时，
# 这样高德卡住时网关还来得及返回带 FALLBACK 标识的估算，而不是让客户端干等到超时
AMAP_TIMEOUT_S = 5.0

# 测试时注入 httpx.MockTransport；生产环境为 None（真实网络）
_transport: httpx.AsyncBaseTransport | None = None


class ProviderUnavailable(RuntimeError):
    """服务商未配置或暂时不可用（→ 503）"""


class UpstreamError(RuntimeError):
    """大模型上游调用失败（→ 502 / 504）"""

    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


class NotFound(LookupError):
    """检索没有结果（→ 404）"""


# ==================== 通用工具 ====================

def _settings() -> config.Settings:
    return config.settings


def _client(timeout: float) -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=timeout, transport=_transport)


def _now_ms() -> int:
    return int(time.time() * 1000)


def today_cn() -> date:
    return datetime.now(CN_TZ).date()


def describe_error(exc: BaseException) -> str:
    """把异常转成不含 URL / 密钥的简短说明"""
    if isinstance(exc, httpx.HTTPStatusError):
        return f"HTTP {exc.response.status_code}"
    if isinstance(exc, httpx.TimeoutException):
        return "请求超时"
    if isinstance(exc, httpx.HTTPError):
        return f"网络错误（{type(exc).__name__}）"
    if isinstance(exc, (ProviderUnavailable, NotFound, UpstreamError)):
        return str(exc)
    return f"数据解析失败（{type(exc).__name__}）"


def _s(value: Any) -> str:
    """高德对空字段返回 [] 而不是空字符串，统一转成 str"""
    return value.strip() if isinstance(value, str) else ""


def _num(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    else:
        text = _s(value)
        if not text:
            return None
        try:
            number = float(text)
        except ValueError:
            return None
    return number if math.isfinite(number) else None


def _parse_point(value: Any) -> tuple[float, float] | None:
    parts = _s(value).split(",")
    if len(parts) != 2:
        return None
    lng, lat = _num(parts[0]), _num(parts[1])
    if lng is None or lat is None or not (-180 <= lng <= 180 and -90 <= lat <= 90) or (lng == 0 and lat == 0):
        return None
    return lng, lat


def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    to_rad = math.pi / 180
    d_lat = (lat2 - lat1) * to_rad
    d_lng = (lng2 - lng1) * to_rad
    a = (math.sin(d_lat / 2) ** 2
         + math.cos(lat1 * to_rad) * math.cos(lat2 * to_rad) * math.sin(d_lng / 2) ** 2)
    return 6371 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


class _TTLCache:
    """进程内小缓存：同一位置的城市编码、同一城市同一天的天气不必反复消耗高德配额"""

    def __init__(self, ttl_s: float, max_items: int = 512) -> None:
        self.ttl_s = ttl_s
        self.max_items = max_items
        self._data: dict[str, tuple[float, Any]] = {}

    def get(self, key: str) -> Any | None:
        item = self._data.get(key)
        if item is None:
            return None
        if time.monotonic() - item[0] > self.ttl_s:
            self._data.pop(key, None)
            return None
        return item[1]

    def set(self, key: str, value: Any) -> None:
        if len(self._data) >= self.max_items:
            for old_key in list(self._data.keys())[: self.max_items // 2]:
                self._data.pop(old_key, None)
        self._data[key] = (time.monotonic(), value)

    def clear(self) -> None:
        self._data.clear()


_regeo_cache = _TTLCache(24 * 3600)
_weather_cache = _TTLCache(20 * 60)


def clear_caches() -> None:
    _regeo_cache.clear()
    _weather_cache.clear()


async def _amap_get(client: httpx.AsyncClient, path: str, params: dict[str, str]) -> dict[str, Any]:
    query = dict(params)
    query["key"] = _settings().amap_api_key
    query["output"] = "JSON"
    response = await client.get(f"{AMAP_BASE}{path}", params=query)
    response.raise_for_status()
    body = response.json()
    if not isinstance(body, dict):
        raise ProviderUnavailable(f"高德 {path} 返回格式异常")
    if str(body.get("status")) != "1":
        info = _s(body.get("info")) or "未知错误"
        raise ProviderUnavailable(f"高德 {path} 调用失败：{info}（{_s(body.get('infocode'))}）")
    return body


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


# ==================== 大模型 ====================

_JSON_HINT = "请只输出一个合法的 JSON 对象，不要输出 Markdown 代码块或任何其他文字。"
_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)
_STATUS_HINT = {
    400: "拒绝了请求格式", 401: "认为 API Key 无效", 402: "账户余额不足", 403: "无权访问该模型",
    404: "找不到接口或模型", 422: "认为请求参数错误", 429: "限流", 500: "内部错误", 503: "繁忙",
}


def _ensure_json_hint(messages: list[dict[str, str]]) -> list[dict[str, str]]:
    """DeepSeek 的 JSON 模式要求提示词里出现 “json” 字样，缺失时由网关补一句"""
    if any("json" in m["content"].lower() for m in messages):
        return messages
    result = [dict(m) for m in messages]
    if result and result[0]["role"] == "system":
        result[0]["content"] = f"{result[0]['content']}\n{_JSON_HINT}"
    else:
        result.insert(0, {"role": "system", "content": _JSON_HINT})
    return result


def coerce_json_object(content: str) -> str | None:
    """去掉代码块围栏并校验是 JSON 对象；无法修复时返回 None"""
    text = _FENCE.sub("", content.strip()).strip()
    if not text:
        return None
    candidates = [text]
    start, end = text.find("{"), text.rfind("}")
    if 0 <= start < end:
        candidates.append(text[start:end + 1])
    for candidate in candidates:
        try:
            value = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(value, dict):
            return json.dumps(value, ensure_ascii=False)
    return None


def _first_choice(data: Any) -> tuple[str, str]:
    choices = _list(_dict(data).get("choices"))
    if not choices:
        return "", ""
    first = _dict(choices[0])
    content = _dict(first.get("message")).get("content")
    return (content if isinstance(content, str) else ""), _s(first.get("finish_reason"))


def _upstream_message(response: httpx.Response, api_key: str) -> str:
    hint = _STATUS_HINT.get(response.status_code, "异常")
    detail = ""
    try:
        error = _dict(response.json()).get("error")
        detail = _s(_dict(error).get("message")) if isinstance(error, dict) else _s(error)
    except ValueError:
        detail = ""
    if api_key:
        detail = detail.replace(api_key, "***")
    detail = detail[:200]
    message = f"上游模型服务{hint}（HTTP {response.status_code}）"
    return f"{message}：{detail}" if detail else message


def _reply(data: Any, content: str, finish: str, s: config.Settings) -> dict[str, Any]:
    body = _dict(data)
    return {
        "id": _s(body.get("id")),
        "object": "chat.completion",
        "model": _s(body.get("model")) or s.llm_model,
        "provider": "deepseek" if s.is_deepseek else "openai-compatible",
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": finish or "stop",
        }],
        "usage": _dict(body.get("usage")),
    }


async def chat_completion(payload: LLMChatRequest) -> dict[str, Any]:
    s = _settings()
    if not s.llm_configured:
        raise ProviderUnavailable("网关未配置 LLM_API_KEY，客户端将使用离线规则理解")

    messages = [{"role": m.role, "content": m.content} for m in payload.messages]
    if payload.json_mode:
        messages = _ensure_json_hint(messages)
    body: dict[str, Any] = {
        "model": s.llm_model,
        "messages": messages,
        "temperature": payload.temperature,
        "max_tokens": min(payload.max_tokens or s.llm_max_tokens, s.llm_max_tokens),
        "stream": False,
    }
    thinking = s.thinking_param()
    if thinking is not None:
        body["thinking"] = thinking
    if payload.json_mode:
        body["response_format"] = {"type": "json_object"}

    url = f"{s.llm_base_url.rstrip('/')}/chat/completions"
    headers = {"Authorization": f"Bearer {s.llm_api_key}", "Content-Type": "application/json"}
    deadline = time.monotonic() + s.llm_timeout_s
    problem = "返回空内容"

    async with _client(s.llm_timeout_s) as client:
        for attempt in range(2):
            remaining = deadline - time.monotonic()
            if remaining < 1.0:
                break
            try:
                response = await client.post(url, json=body, headers=headers, timeout=remaining)
            except httpx.TimeoutException as exc:
                raise UpstreamError(504, "上游模型服务响应超时") from exc
            except httpx.HTTPError as exc:
                raise UpstreamError(502, f"无法连接上游模型服务（{type(exc).__name__}）") from exc
            if response.status_code != 200:
                raise UpstreamError(502, _upstream_message(response, s.llm_api_key))
            try:
                data = response.json()
            except ValueError as exc:
                raise UpstreamError(502, "上游模型服务返回的不是 JSON") from exc

            content, finish = _first_choice(data)
            if payload.json_mode:
                fixed = coerce_json_object(content)
                if fixed is not None:
                    return _reply(data, fixed, finish, s)
                if finish == "length":
                    problem = "输出被截断（可调大 LLM_MAX_TOKENS）"
                    break
                problem = "返回空内容" if not content.strip() else "返回的不是合法 JSON"
            elif content.strip():
                return _reply(data, content, finish, s)
            logger.warning("llm attempt %d unusable: %s", attempt + 1, problem)
            if deadline - time.monotonic() < 4.0:
                break
    raise UpstreamError(502, f"上游模型{problem}")


# ==================== 天气 ====================

async def _regeo(client: httpx.AsyncClient, lng: float, lat: float) -> tuple[str, str]:
    """坐标 → (区县 adcode, 城市名)。直辖市的 city 字段为空，用省名代替"""
    cache_key = f"{lng:.3f},{lat:.3f}"
    cached = _regeo_cache.get(cache_key)
    if cached is not None:
        return cached
    body = await _amap_get(client, "/v3/geocode/regeo",
                           {"location": f"{lng:.6f},{lat:.6f}", "extensions": "base"})
    component = _dict(_dict(body.get("regeocode")).get("addressComponent"))
    adcode = _s(component.get("adcode"))
    if not re.fullmatch(r"\d{6}", adcode):
        raise ProviderUnavailable("该位置不在高德行政区范围内")
    result = (adcode, _s(component.get("city")) or _s(component.get("province")))
    _regeo_cache.set(cache_key, result)
    return result


async def _live_weather(client: httpx.AsyncClient, adcode: str) -> tuple[str, str, str, bool, str | None]:
    body = await _amap_get(client, "/v3/weather/weatherInfo", {"city": adcode, "extensions": "base"})
    lives = _list(body.get("lives"))
    live = _dict(lives[0]) if lives else {}
    weather = _s(live.get("weather"))
    if not weather:
        raise ProviderUnavailable("高德没有返回实况天气")
    temperature = _s(live.get("temperature"))
    return weather, (f"{temperature}℃" if temperature else ""), _s(live.get("city")), False, None


async def _forecast_weather(client: httpx.AsyncClient, adcode: str,
                            date_text: str) -> tuple[str, str, str, bool, str | None]:
    body = await _amap_get(client, "/v3/weather/weatherInfo", {"city": adcode, "extensions": "all"})
    forecasts = _list(body.get("forecasts"))
    forecast = _dict(forecasts[0]) if forecasts else {}
    if not forecast:
        raise ProviderUnavailable("高德没有返回天气预报")
    district = _s(forecast.get("city"))
    for cast in _list(forecast.get("casts")):
        cast = _dict(cast)
        if _s(cast.get("date")) != date_text:
            continue
        day_weather = _s(cast.get("dayweather")) or _s(cast.get("nightweather"))
        if not day_weather:
            break
        low, high = _s(cast.get("nighttemp")), _s(cast.get("daytemp"))
        night = _s(cast.get("nightweather"))
        note = f"夜间{night}" if night and night != day_weather else None
        return day_weather, (f"{low}~{high}℃" if low and high else ""), district, True, note
    return NO_FORECAST, "", district, False, "高德预报中暂无该日期"


def _fallback_weather(date_text: str | None, reason: str) -> WeatherResponse:
    if not _settings().allow_demo_fallback:
        raise ProviderUnavailable(f"天气服务不可用：{reason}")
    return WeatherResponse(
        weather=DEMO_WEATHER, date=date_text, is_forecast=False,
        data_source="FALLBACK", provider="offline-demo", updated_at=_now_ms(),
        note=f"演示数据：{reason}",
    )


async def get_weather(lng: float | None, lat: float | None, city_code: str | None,
                      target: date | None) -> WeatherResponse:
    """city_code 优先；否则按坐标逆地理编码。target 为空时返回实况，否则返回该日预报"""
    date_text = target.isoformat() if target is not None else None
    if not _settings().amap_configured:
        return _fallback_weather(date_text, "AMAP_API_KEY 未配置")
    delta = (target - today_cn()).days if target is not None else None
    try:
        async with _client(AMAP_TIMEOUT_S) as client:
            city_name = ""
            if city_code:
                adcode = city_code
            elif lng is not None and lat is not None:
                adcode, city_name = await _regeo(client, lng, lat)
            else:
                raise ProviderUnavailable("缺少位置")
            if delta is not None and delta > FORECAST_DAYS:
                return WeatherResponse(
                    weather=NO_FORECAST, city=city_name, date=date_text, is_forecast=False,
                    data_source="REALTIME_API", provider="amap", updated_at=_now_ms(),
                    note=f"高德只提供 {FORECAST_DAYS + 1} 天内的预报，临近就诊日再查询",
                )
            cache_key = f"{adcode}|{date_text or 'live'}"
            result = _weather_cache.get(cache_key)
            if result is None:
                if date_text is None:
                    result = await _live_weather(client, adcode)
                else:
                    result = await _forecast_weather(client, adcode, date_text)
                _weather_cache.set(cache_key, result)
        weather, temperature, district, is_forecast, note = result
        return WeatherResponse(
            weather=weather, temperature=temperature, city=city_name or district, date=date_text,
            is_forecast=is_forecast, data_source="REALTIME_API", provider="amap",
            updated_at=_now_ms(), note=note,
        )
    except (httpx.HTTPError, ValueError, KeyError, TypeError, ProviderUnavailable) as exc:
        reason = describe_error(exc)
        logger.warning("weather failed: %s", reason)
        return _fallback_weather(date_text, reason)


# ==================== 医院检索 ====================

@dataclass
class _Poi:
    name: str
    address: str
    lng: float
    lat: float
    city: str
    district: str
    typecode: str
    distance_km: float | None
    score: float = 0.0


# 宠物医院、药店等不是老人要去的“医院”
_EXCLUDE_NAME = re.compile(r"宠物|动物|兽医|药房|药店")
# 医院的门、楼、停车场等附属点位，优先级降低
_SUB_POI = re.compile(r"停车场|出入口|[东南西北正侧后]门|号楼|住院部|门诊楼|急诊楼|收费处|挂号处")


def clean_hospital_keyword(keyword: str) -> str:
    text = re.sub(r"\s+", "", keyword)
    text = re.sub(r"^(去|到|在)", "", text)
    text = re.sub(r"(看病|挂号|就诊|复诊|看门诊)$", "", text)
    return text[:50]


def _parse_pois(body: dict[str, Any]) -> list[_Poi]:
    result: list[_Poi] = []
    for item in _list(body.get("pois")):
        item = _dict(item)
        name = _s(item.get("name"))
        point = _parse_point(item.get("location"))
        if not name or point is None:
            continue
        distance_m = _num(item.get("distance"))
        result.append(_Poi(
            name=name, address=_s(item.get("address")), lng=point[0], lat=point[1],
            city=_s(item.get("cityname")) or _s(item.get("pname")), district=_s(item.get("adname")),
            typecode=_s(item.get("typecode")),
            distance_km=round(distance_m / 1000, 1) if distance_m is not None else None,
        ))
    return result


def rank_hospitals(pois: list[_Poi], keyword: str) -> list[_Poi]:
    """名称匹配 + 医院类型 + 距离综合打分；和关键词重合不到一半的结果直接丢弃"""
    chars = set(keyword)
    ranked: list[_Poi] = []
    for poi in pois:
        code = poi.typecode
        if code.startswith(("0906", "0907")) or _EXCLUDE_NAME.search(poi.name):
            continue
        overlap = len(chars & set(poi.name)) / len(chars) if chars else 0.0
        if keyword not in poi.name and overlap < 0.5:
            continue
        score = 4.0 if keyword in poi.name else 3.0 * overlap
        if code.startswith("0901"):
            score += 3      # 综合医院
        elif code.startswith("0902"):
            score += 2      # 专科医院
        elif code.startswith("0904"):
            score += 1      # 急救中心
        elif code.startswith("0903"):
            score -= 1      # 诊所
        if "医院" in poi.name:
            score += 0.5
        if _SUB_POI.search(poi.name):
            score -= 2
        if poi.distance_km is not None:
            score -= min(poi.distance_km / 25, 2.0)
        poi.score = score
        ranked.append(poi)
    ranked.sort(key=lambda p: p.score, reverse=True)
    return ranked


async def _find_hospitals(client: httpx.AsyncClient, keyword: str, lng: float | None,
                          lat: float | None) -> list[_Poi]:
    """先在用户周边 50 公里内按综合排序检索，没有再全国检索（异地就医，如“上海瑞金医院”）"""
    ranked: list[_Poi] = []
    if lng is not None and lat is not None:
        body = await _amap_get(client, "/v3/place/around", {
            "location": f"{lng:.6f},{lat:.6f}", "keywords": keyword, "types": HOSPITAL_TYPES,
            "radius": "50000", "sortrule": "weight", "offset": "20", "page": "1", "extensions": "base",
        })
        ranked = rank_hospitals(_parse_pois(body), keyword)
    if not ranked:
        body = await _amap_get(client, "/v3/place/text", {
            "keywords": keyword, "types": HOSPITAL_TYPES, "citylimit": "false",
            "offset": "20", "page": "1", "extensions": "base",
        })
        ranked = rank_hospitals(_parse_pois(body), keyword)
    return ranked


async def search_hospital(keyword: str, lng: float | None, lat: float | None) -> HospitalResponse:
    if not _settings().amap_configured:
        raise ProviderUnavailable("医院检索需要在网关配置 AMAP_API_KEY")
    cleaned = clean_hospital_keyword(keyword)
    if len(cleaned) < 2:
        raise NotFound("医院名称太短")
    try:
        async with _client(AMAP_TIMEOUT_S) as client:
            ranked = await _find_hospitals(client, cleaned, lng, lat)
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        raise ProviderUnavailable(f"医院检索失败：{describe_error(exc)}") from exc
    if not ranked:
        raise NotFound(f"没有找到“{cleaned}”")
    best = ranked[0]
    return HospitalResponse(
        name=best.name, address=best.address, lng=best.lng, lat=best.lat, city=best.city,
        district=best.district, distance_km=best.distance_km, data_source="REALTIME_API", provider="amap",
        alternatives=[HospitalBrief(name=p.name, address=p.address, distance_km=p.distance_km)
                      for p in ranked[1:4]],
    )


# ==================== 出行路线 ====================

_HAS_DIGIT = re.compile(r"\d")
_STREET_WORD = re.compile(r"[路街道巷弄号]")


async def _geocode(client: httpx.AsyncClient, address: str) -> tuple[float, float] | None:
    body = await _amap_get(client, "/v3/geocode/geo", {"address": address})
    geocodes = _list(body.get("geocodes"))
    return _parse_point(_dict(geocodes[0]).get("location")) if geocodes else None


async def _resolve_destination(client: httpx.AsyncClient, address: str, origin_lng: float,
                               origin_lat: float) -> tuple[tuple[float, float], str | None]:
    """目的地没有坐标时：像门牌地址的先地理编码，像医院名的先 POI 检索，两者互为补充"""
    looks_like_street = bool(_HAS_DIGIT.search(address) and _STREET_WORD.search(address))
    if looks_like_street:
        point = await _geocode(client, address)
        if point is not None:
            return point, None
    keyword = clean_hospital_keyword(address)
    if len(keyword) >= 2:
        ranked = await _find_hospitals(client, keyword, origin_lng, origin_lat)
        if ranked:
            return (ranked[0].lng, ranked[0].lat), ranked[0].name
    if not looks_like_street:
        point = await _geocode(client, address)
        if point is not None:
            return point, None
    raise NotFound("没能定位目的地")


def traffic_level(duration_sec: int, distance_m: int) -> str:
    """按平均车速粗分路况：≥30km/h 畅通，≥15km/h 缓行，否则拥堵"""
    if duration_sec <= 0:
        return "畅通"
    speed_kmh = distance_m / 1000 / (duration_sec / 3600)
    if speed_kmh >= 30:
        return "畅通"
    if speed_kmh >= 15:
        return "缓行"
    return "拥堵"


def _fallback_route(request: RouteRequest, dest: tuple[float, float] | None, reason: str) -> RouteResponse:
    if not _settings().allow_demo_fallback:
        raise ProviderUnavailable(f"路线服务不可用：{reason}")
    if dest is not None:
        # 与客户端 TravelService.estimate 同一公式：直线距离 × 1.4 绕行系数，城市均速 25km/h
        km = haversine_km(request.origin_lat, request.origin_lng, dest[1], dest[0]) * 1.4
        return RouteResponse(
            duration_min=max(8, round(km / 25 * 60) + 5), distance_km=max(0.1, round(km, 1)),
            traffic_level="未知", data_source="FALLBACK", provider="estimate", updated_at=_now_ms(),
            dest_lng=dest[0], dest_lat=dest[1], note=f"按直线距离估算：{reason}",
        )
    return RouteResponse(
        duration_min=28, distance_km=9.6, traffic_level="缓行", data_source="FALLBACK",
        provider="offline-demo", updated_at=_now_ms(), note=f"演示数据：{reason}",
    )


async def get_route(request: RouteRequest) -> RouteResponse:
    dest = request.dest_point()
    if not _settings().amap_configured:
        return _fallback_route(request, dest, "AMAP_API_KEY 未配置")
    dest_name: str | None = None
    try:
        async with _client(AMAP_TIMEOUT_S) as client:
            if dest is None:
                dest, dest_name = await _resolve_destination(
                    client, request.dest_address, request.origin_lng, request.origin_lat)
            body = await _amap_get(client, "/v3/direction/driving", {
                "origin": f"{request.origin_lng:.6f},{request.origin_lat:.6f}",
                "destination": f"{dest[0]:.6f},{dest[1]:.6f}",
                "strategy": "10", "extensions": "base",
            })
        paths = _list(_dict(body.get("route")).get("paths"))
        path = _dict(paths[0]) if paths else {}
        duration_sec = int(_num(path.get("duration")) or 0)
        distance_m = int(_num(path.get("distance")) or 0)
        if duration_sec <= 0 or distance_m <= 0:
            raise ProviderUnavailable("高德没有返回可用路线")
        return RouteResponse(
            duration_min=max(1, round(duration_sec / 60)),
            distance_km=max(0.1, round(distance_m / 100) / 10),
            traffic_level=traffic_level(duration_sec, distance_m),
            data_source="REALTIME_API", provider="amap", updated_at=_now_ms(),
            dest_lng=dest[0], dest_lat=dest[1], dest_name=dest_name,
        )
    except (httpx.HTTPError, ValueError, KeyError, TypeError, ProviderUnavailable, NotFound) as exc:
        reason = describe_error(exc)
        logger.warning("route failed: %s", reason)
        return _fallback_route(request, dest, reason)
