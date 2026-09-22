from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app import providers


client = TestClient(app)


@pytest.fixture(autouse=True)
def force_offline_provider_config(monkeypatch: pytest.MonkeyPatch) -> None:
    """CI must never call paid/external providers even if runner variables are present."""
    offline = replace(
        providers.settings,
        llm_api_key="",
        amap_api_key="",
        allow_demo_fallback=True,
    )
    monkeypatch.setattr(providers, "settings", offline)


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_weather_fallback_is_explicit() -> None:
    response = client.get("/v1/weather?city_code=110000")
    assert response.status_code == 200
    body = response.json()
    assert body["data_source"] == "FALLBACK"
    assert body["provider"] == "offline-demo"


def test_route_fallback_is_explicit() -> None:
    response = client.post(
        "/v1/travel/route",
        json={
            "origin_lng": 116.4074,
            "origin_lat": 39.9042,
            "destination_address": "北京市第一医院",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["data_source"] == "FALLBACK"
    assert body["duration_min"] > 0


def test_route_rejects_invalid_coordinates() -> None:
    response = client.post(
        "/v1/travel/route",
        json={"origin_lng": 999, "origin_lat": 39.9, "destination_address": "医院"},
    )
    assert response.status_code == 422


def test_llm_requires_server_key() -> None:
    response = client.post(
        "/v1/llm/chat",
        json={"messages": [{"role": "user", "content": "你好"}]},
    )
    assert response.status_code == 503
