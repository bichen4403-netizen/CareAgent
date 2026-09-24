"""
网关接口测试。

CI 与本地测试绝不调用付费 / 外部服务：默认配置清空所有密钥，并注入一个“任何网络请求都算失败”的传输层；
需要验证真实调用路径的用例，用 httpx.MockTransport 模拟 DeepSeek 与高德的返回。
"""
import json
from dataclasses import replace
from datetime import timedelta
from typing import Callable

import httpx
import pytest
from fastapi.testclient import TestClient

from app import config, main, providers

client = TestClient(main.app)

FAKE_LLM_KEY = "sk-test-secret-123456"
FAKE_AMAP_KEY = "amap-test-secret-abcdef"
HANGZHOU = {"lng": 120.1551, "lat": 30.2741}


def _no_network(request: httpx.Request) -> httpx.Response:
    raise AssertionError(f"unexpected network call: {request.url.path}")


@pytest.fixture(autouse=True)
def offline(monkeypatch: pytest.MonkeyPatch) -> None:
    """默认离线：无密钥、允许演示兜底、无访问令牌、限流放宽"""
    monkeypatch.setattr(config, "settings", replace(
        config.settings,
        llm_api_key="", amap_api_key="", app_access_token="",
        llm_base_url="https://api.deepseek.com", llm_model="deepseek-flash", llm_thinking="auto",
        llm_max_tokens=1024, llm_timeout_s=12.0,
        allow_demo_fallback=True, rate_limit_per_min=1000, llm_rate_limit_per_min=1000,
        trust_proxy_headers=False,
    ))
    monkeypatch.setattr(providers, "_transport", httpx.MockTransport(_no_network))
    providers.clear_caches()
    main.limiter.reset()


def use_settings(monkeypatch: pytest.MonkeyPatch, **changes: object) -> None:
    monkeypatch.setattr(config, "settings", replace(config.settings, **changes))


def use_upstream(monkeypatch: pytest.MonkeyPatch,
                 handler: Callable[[httpx.Request], httpx.Response]) -> list[httpx.Request]:
    calls: list[httpx.Request] = []

    def recording(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return handler(request)

    monkeypatch.setattr(providers, "_transport", httpx.MockTransport(recording))
    return calls


def amap_ok(**body: object) -> httpx.Response:
    payload = {"status": "1", "info": "OK", "infocode": "10000"}
    payload.update(body)
    return httpx.Response(200, json=payload)


def llm_ok(content: str, finish: str = "stop") -> httpx.Response:
    return httpx.Response(200, json={
        "id": "chatcmpl-1", "model": "deepseek-flash",
        "choices": [{"index": 0, "finish_reason": finish,
                     "message": {"role": "assistant", "content": content, "reasoning_content": "内部思考"}}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
    })


def day(offset: int) -> str:
    return (providers.today_cn() + timedelta(days=offset)).isoformat()


# ==================== 基础 / 离线兜底 ====================

def test_health_reports_configuration() -> None:
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert body["llm_configured"] is False
    assert body["amap_configured"] is False
    assert body["llm_model"] == "deepseek-flash"
    assert body["token_required"] is False


def test_default_model_is_current_deepseek_name() -> None:
    assert config.DEFAULT_LLM_MODEL == "deepseek-flash"
    assert config.DEFAULT_LLM_BASE_URL == "https://api.deepseek.com"


def test_weather_requires_location() -> None:
    assert client.get("/v1/weather").status_code == 422


def test_weather_fallback_is_explicit() -> None:
    response = client.get("/v1/weather", params=HANGZHOU)
    assert response.status_code == 200
    body = response.json()
    assert body["data_source"] == "FALLBACK"
    assert body["provider"] == "offline-demo"
    assert body["weather"] == "小雨"


def test_weather_rejects_past_date() -> None:
    response = client.get("/v1/weather", params={**HANGZHOU, "date": day(-1)})
    assert response.status_code == 422


def test_weather_without_fallback_fails_loudly(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, allow_demo_fallback=False)
    response = client.get("/v1/weather", params=HANGZHOU)
    assert response.status_code == 503


def test_route_fallback_is_explicit() -> None:
    response = client.post("/v1/travel/route", json={
        "origin_lng": 116.4074, "origin_lat": 39.9042, "dest_address": "北京市第一医院", "mode": "driving"})
    assert response.status_code == 200
    body = response.json()
    assert body["data_source"] == "FALLBACK"
    assert body["duration_min"] == 28


def test_route_fallback_estimates_from_known_coordinates() -> None:
    response = client.post("/v1/travel/route", json={
        "origin_lng": 120.1551, "origin_lat": 30.2741, "dest_address": "浙江省人民医院",
        "dest_lng": 120.1650, "dest_lat": 30.3050})
    body = response.json()
    assert response.status_code == 200
    assert body["provider"] == "estimate"
    assert body["data_source"] == "FALLBACK"
    assert body["traffic_level"] == "未知"
    assert 8 <= body["duration_min"] <= 30


def test_route_accepts_legacy_destination_field() -> None:
    response = client.post("/v1/travel/route", json={
        "origin_lng": 116.4074, "origin_lat": 39.9042, "destination_address": "北京协和医院"})
    assert response.status_code == 200


def test_route_rejects_invalid_coordinates() -> None:
    response = client.post("/v1/travel/route", json={
        "origin_lng": 999, "origin_lat": 39.9, "dest_address": "医院"})
    assert response.status_code == 422


def test_route_rejects_half_destination_coordinates() -> None:
    response = client.post("/v1/travel/route", json={
        "origin_lng": 120.1, "origin_lat": 30.2, "dest_address": "某某医院", "dest_lng": 120.2})
    assert response.status_code == 422


def test_hospital_search_needs_amap_key() -> None:
    response = client.get("/v1/hospital/search", params={"keyword": "第一人民医院", **HANGZHOU})
    assert response.status_code == 503


def test_llm_requires_server_key() -> None:
    response = client.post("/v1/llm/chat", json={"messages": [{"role": "user", "content": "你好"}]})
    assert response.status_code == 503


def test_llm_rejects_streaming() -> None:
    response = client.post("/v1/llm/chat", json={
        "messages": [{"role": "user", "content": "你好"}], "stream": True})
    assert response.status_code == 422


# ==================== 访问控制 ====================

def test_app_token_is_enforced(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, app_access_token="s3cret-token")
    assert client.get("/health").status_code == 200
    assert client.get("/v1/weather", params=HANGZHOU).status_code == 401
    assert client.get("/v1/weather", params=HANGZHOU, headers={"X-App-Token": "wrong"}).status_code == 401
    ok = client.get("/v1/weather", params=HANGZHOU, headers={"X-App-Token": "s3cret-token"})
    assert ok.status_code == 200


def test_rate_limit_returns_429(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, rate_limit_per_min=2)
    assert client.get("/v1/weather", params=HANGZHOU).status_code == 200
    assert client.get("/v1/weather", params=HANGZHOU).status_code == 200
    blocked = client.get("/v1/weather", params=HANGZHOU)
    assert blocked.status_code == 429
    assert int(blocked.headers["Retry-After"]) >= 1


def test_llm_has_its_own_rate_limit(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_rate_limit_per_min=1)
    payload = {"messages": [{"role": "user", "content": "你好"}]}
    assert client.post("/v1/llm/chat", json=payload).status_code == 503   # 未配置密钥，但计入次数
    assert client.post("/v1/llm/chat", json=payload).status_code == 429
    assert client.get("/v1/weather", params=HANGZHOU).status_code == 200   # 其他接口不受影响


# ==================== 大模型（模拟 DeepSeek） ====================

def test_llm_json_mode_request_shape(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY)
    calls = use_upstream(monkeypatch, lambda request: llm_ok('{"type": "MEDICAL_VISIT"}'))
    response = client.post("/v1/llm/chat", json={
        "messages": [{"role": "system", "content": "你是陪诊助手"}, {"role": "user", "content": "明天去看心内科"}],
        "temperature": 0.1, "json_mode": True, "model": "deepseek-v4-pro"})
    assert response.status_code == 200
    sent = json.loads(calls[0].content)
    assert str(calls[0].url) == "https://api.deepseek.com/chat/completions"
    assert calls[0].headers["Authorization"] == f"Bearer {FAKE_LLM_KEY}"
    assert sent["model"] == "deepseek-flash"                 # 客户端不能自选模型
    assert sent["response_format"] == {"type": "json_object"}
    assert sent["thinking"] == {"type": "disabled"}          # DeepSeek 默认开思考，意图理解要关掉
    assert sent["max_tokens"] == 1024
    assert sent["stream"] is False
    assert "json" in sent["messages"][0]["content"].lower()  # JSON 模式要求提示词含 json 字样
    body = response.json()
    assert json.loads(body["choices"][0]["message"]["content"]) == {"type": "MEDICAL_VISIT"}
    assert "reasoning_content" not in body["choices"][0]["message"]
    assert body["provider"] == "deepseek"


def test_llm_strips_code_fence(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY)
    use_upstream(monkeypatch, lambda request: llm_ok('```json\n{"hospital": "浙江省人民医院"}\n```'))
    response = client.post("/v1/llm/chat", json={
        "messages": [{"role": "user", "content": "输出 JSON"}], "json_mode": True})
    assert response.status_code == 200
    content = response.json()["choices"][0]["message"]["content"]
    assert json.loads(content) == {"hospital": "浙江省人民医院"}


def test_llm_retries_empty_json_once(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY)
    replies = [llm_ok(""), llm_ok('{"ok": true}')]
    calls = use_upstream(monkeypatch, lambda request: replies.pop(0))
    response = client.post("/v1/llm/chat", json={
        "messages": [{"role": "user", "content": "输出 JSON"}], "json_mode": True})
    assert response.status_code == 200
    assert len(calls) == 2


def test_llm_invalid_json_twice_is_502(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY)
    use_upstream(monkeypatch, lambda request: llm_ok("好的，我来帮您"))
    response = client.post("/v1/llm/chat", json={
        "messages": [{"role": "user", "content": "输出 JSON"}], "json_mode": True})
    assert response.status_code == 502


def test_llm_upstream_error_is_502_without_key(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY)
    use_upstream(monkeypatch, lambda request: httpx.Response(
        401, json={"error": {"message": f"Authentication Fails, key {FAKE_LLM_KEY} is invalid"}}))
    response = client.post("/v1/llm/chat", json={"messages": [{"role": "user", "content": "你好"}]})
    assert response.status_code == 502
    assert FAKE_LLM_KEY not in response.text
    assert "401" in response.json()["detail"]


def test_llm_model_not_exist_is_reported(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY, llm_model="deepseek-chat")
    use_upstream(monkeypatch, lambda request: httpx.Response(400, json={"error": {"message": "Model Not Exist"}}))
    response = client.post("/v1/llm/chat", json={"messages": [{"role": "user", "content": "你好"}]})
    assert response.status_code == 502
    assert "Model Not Exist" in response.json()["detail"]


def test_llm_timeout_is_504(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY)

    def slow(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out", request=request)

    use_upstream(monkeypatch, slow)
    response = client.post("/v1/llm/chat", json={"messages": [{"role": "user", "content": "你好"}]})
    assert response.status_code == 504


def test_llm_thinking_param_omitted_for_other_providers(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, llm_api_key=FAKE_LLM_KEY, llm_model="qwen-plus",
                 llm_base_url="https://dashscope.aliyuncs.com/compatible-mode/v1")
    calls = use_upstream(monkeypatch, lambda request: llm_ok("你好"))
    response = client.post("/v1/llm/chat", json={"messages": [{"role": "user", "content": "你好"}]})
    assert response.status_code == 200
    sent = json.loads(calls[0].content)
    assert "thinking" not in sent
    assert "response_format" not in sent
    assert str(calls[0].url) == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    assert response.json()["provider"] == "openai-compatible"


# ==================== 天气（模拟高德） ====================

def weather_handler(casts_from_today: list[tuple[str, str]], city: object = "杭州市",
                    province: str = "浙江省") -> Callable[[httpx.Request], httpx.Response]:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.params["key"] == FAKE_AMAP_KEY
        if request.url.path == "/v3/geocode/regeo":
            return amap_ok(regeocode={"addressComponent": {"adcode": "330106", "city": city, "province": province}})
        if request.url.path == "/v3/weather/weatherInfo":
            if request.url.params["extensions"] == "base":
                return amap_ok(lives=[{"city": "西湖区", "weather": "多云", "temperature": "23"}])
            casts = [{"date": day(i), "dayweather": d, "nightweather": n, "daytemp": "24", "nighttemp": "18"}
                     for i, (d, n) in enumerate(casts_from_today)]
            return amap_ok(forecasts=[{"city": "西湖区", "adcode": "330106", "casts": casts}])
        raise AssertionError(f"unexpected path {request.url.path}")
    return handler


def test_weather_live_uses_regeo_city(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    use_upstream(monkeypatch, weather_handler([]))
    body = client.get("/v1/weather", params=HANGZHOU).json()
    assert body["weather"] == "多云"
    assert body["temperature"] == "23℃"
    assert body["city"] == "杭州市"
    assert body["is_forecast"] is False
    assert body["data_source"] == "REALTIME_API"


def test_weather_forecast_for_visit_day(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    calls = use_upstream(monkeypatch, weather_handler([("晴", "晴"), ("中雨", "小雨"), ("阴", "阴"), ("晴", "晴")]))
    body = client.get("/v1/weather", params={**HANGZHOU, "date": day(1)}).json()
    assert body["weather"] == "中雨"
    assert body["is_forecast"] is True
    assert body["temperature"] == "18~24℃"
    assert body["date"] == day(1)
    assert body["note"] == "夜间小雨"
    # 同一位置再次查询走缓存，不再消耗高德配额
    client.get("/v1/weather", params={**HANGZHOU, "date": day(1)})
    assert len(calls) == 2


def test_weather_beyond_forecast_range(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    calls = use_upstream(monkeypatch, weather_handler([]))
    body = client.get("/v1/weather", params={**HANGZHOU, "date": day(6)}).json()
    assert body["weather"] == "暂无预报"
    assert body["is_forecast"] is False
    assert all(c.url.path != "/v3/weather/weatherInfo" for c in calls)


def test_weather_municipality_uses_province_name(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    use_upstream(monkeypatch, weather_handler([], city=[], province="北京市"))
    body = client.get("/v1/weather", params={"lng": 116.4074, "lat": 39.9042}).json()
    assert body["city"] == "北京市"


def test_weather_amap_error_falls_back_without_leaking_key(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    use_upstream(monkeypatch, lambda request: httpx.Response(500, text="boom"))
    body = client.get("/v1/weather", params=HANGZHOU).json()
    assert body["data_source"] == "FALLBACK"
    use_settings(monkeypatch, allow_demo_fallback=False)
    providers.clear_caches()
    response = client.get("/v1/weather", params=HANGZHOU)
    assert response.status_code == 503
    assert FAKE_AMAP_KEY not in response.text


# ==================== 医院检索 / 路线（模拟高德） ====================

POIS_NEAR_HANGZHOU = [
    {"name": "第一人民宠物医院", "typecode": "090701", "location": "120.156,30.275", "distance": "300",
     "address": "某路1号", "cityname": "杭州市", "adname": "上城区"},
    {"name": "第一人民医院门诊部", "typecode": "090300", "location": "120.160,30.280", "distance": "900",
     "address": [], "cityname": "杭州市", "adname": "上城区"},
    {"name": "杭州市第一人民医院", "typecode": "090101", "location": "120.170,30.250", "distance": "3200",
     "address": "浣纱路261号", "cityname": "杭州市", "adname": "上城区"},
    {"name": "杭州市第一人民医院-东门", "typecode": "090101", "location": "120.171,30.251", "distance": "3300",
     "address": [], "cityname": "杭州市", "adname": "上城区"},
]


def test_hospital_search_prefers_general_hospital(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    calls = use_upstream(monkeypatch, lambda request: amap_ok(pois=POIS_NEAR_HANGZHOU))
    response = client.get("/v1/hospital/search", params={"keyword": "第一人民医院", **HANGZHOU})
    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "杭州市第一人民医院"
    assert body["address"] == "浣纱路261号"
    assert body["lng"] == pytest.approx(120.170)
    assert body["city"] == "杭州市"
    assert all("宠物" not in alt["name"] for alt in body["alternatives"])
    assert calls[0].url.path == "/v3/place/around"
    assert calls[0].url.params["radius"] == "50000"


def test_hospital_search_falls_back_to_nationwide(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v3/place/around":
            return amap_ok(pois=[])
        return amap_ok(pois=[{"name": "上海交通大学医学院附属瑞金医院", "typecode": "090101",
                              "location": "121.466,31.212", "address": "瑞金二路197号", "cityname": "上海市"}])

    use_upstream(monkeypatch, handler)
    body = client.get("/v1/hospital/search", params={"keyword": "瑞金医院", **HANGZHOU}).json()
    assert body["name"] == "上海交通大学医学院附属瑞金医院"
    assert body["distance_km"] is None


def test_hospital_search_not_found(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    use_upstream(monkeypatch, lambda request: amap_ok(pois=[]))
    response = client.get("/v1/hospital/search", params={"keyword": "不存在的医院名", **HANGZHOU})
    assert response.status_code == 404


def driving_ok(duration_s: int, distance_m: int) -> httpx.Response:
    return amap_ok(route={"paths": [{"duration": str(duration_s), "distance": str(distance_m)}]})


def test_route_realtime_with_destination_coordinates(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    calls = use_upstream(monkeypatch, lambda request: driving_ok(1800, 12000))
    body = client.post("/v1/travel/route", json={
        "origin_lng": 120.1551, "origin_lat": 30.2741, "dest_address": "杭州市第一人民医院",
        "dest_lng": 120.170, "dest_lat": 30.250, "mode": "driving"}).json()
    assert body["duration_min"] == 30
    assert body["distance_km"] == 12.0
    assert body["traffic_level"] == "缓行"          # 24 km/h
    assert body["data_source"] == "REALTIME_API"
    assert [c.url.path for c in calls] == ["/v3/direction/driving"]
    assert calls[0].url.params["destination"] == "120.170000,30.250000"


def test_route_resolves_hospital_name_via_poi(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v3/place/around":
            return amap_ok(pois=POIS_NEAR_HANGZHOU)
        if request.url.path == "/v3/direction/driving":
            return driving_ok(900, 9000)
        raise AssertionError(f"unexpected path {request.url.path}")

    use_upstream(monkeypatch, handler)
    body = client.post("/v1/travel/route", json={
        "origin_lng": 120.1551, "origin_lat": 30.2741, "dest_address": "第一人民医院"}).json()
    assert body["dest_name"] == "杭州市第一人民医院"
    assert body["traffic_level"] == "畅通"          # 36 km/h
    assert body["data_source"] == "REALTIME_API"


def test_route_street_address_uses_geocoding(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v3/geocode/geo":
            return amap_ok(geocodes=[{"location": "120.170000,30.250000"}])
        if request.url.path == "/v3/direction/driving":
            return driving_ok(2400, 6000)
        raise AssertionError(f"unexpected path {request.url.path}")

    calls = use_upstream(monkeypatch, handler)
    body = client.post("/v1/travel/route", json={
        "origin_lng": 120.1551, "origin_lat": 30.2741, "dest_address": "杭州市上城区浣纱路261号"}).json()
    assert body["traffic_level"] == "拥堵"          # 9 km/h
    assert calls[0].url.path == "/v3/geocode/geo"


def test_route_amap_key_error_falls_back_without_leaking_key(monkeypatch: pytest.MonkeyPatch) -> None:
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY)
    use_upstream(monkeypatch, lambda request: httpx.Response(
        200, json={"status": "0", "info": "INVALID_USER_KEY", "infocode": "10001"}))
    payload = {"origin_lng": 120.1551, "origin_lat": 30.2741, "dest_address": "浙江省人民医院",
               "dest_lng": 120.165, "dest_lat": 30.305}
    body = client.post("/v1/travel/route", json=payload).json()
    assert body["data_source"] == "FALLBACK"
    assert body["provider"] == "estimate"
    assert "INVALID_USER_KEY" in body["note"]
    use_settings(monkeypatch, allow_demo_fallback=False)
    response = client.post("/v1/travel/route", json=payload)
    assert response.status_code == 503
    assert FAKE_AMAP_KEY not in response.text


def test_route_http_error_message_never_contains_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """httpx 的 HTTPStatusError 文本里带完整 URL（含 key），必须脱敏"""
    use_settings(monkeypatch, amap_api_key=FAKE_AMAP_KEY, allow_demo_fallback=False)
    use_upstream(monkeypatch, lambda request: httpx.Response(403, text="forbidden"))
    response = client.post("/v1/travel/route", json={
        "origin_lng": 120.1551, "origin_lat": 30.2741, "dest_address": "浙江省人民医院",
        "dest_lng": 120.165, "dest_lat": 30.305})
    assert response.status_code == 503
    assert FAKE_AMAP_KEY not in response.text
    assert "HTTP 403" in response.json()["detail"]


def test_traffic_level_thresholds() -> None:
    assert providers.traffic_level(600, 6000) == "畅通"     # 36 km/h
    assert providers.traffic_level(1200, 6000) == "缓行"    # 18 km/h
    assert providers.traffic_level(1800, 3000) == "拥堵"    # 6 km/h
