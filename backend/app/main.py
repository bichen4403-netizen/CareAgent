from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv

load_dotenv()

from .config import settings  # noqa: E402
from .models import LLMChatRequest, RouteRequest, RouteResponse, WeatherResponse  # noqa: E402
from .providers import ProviderUnavailable, chat_completion, get_route, get_weather  # noqa: E402


app = FastAPI(title="CareAgent Gateway", version="0.1.0")
origins = [item.strip() for item in settings.cors_origins.split(",") if item.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "Authorization"],
)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "careagent-gateway"}


@app.post("/v1/llm/chat")
async def llm_chat(payload: LLMChatRequest) -> dict:
    try:
        return await chat_completion(payload)
    except ProviderUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/v1/weather", response_model=WeatherResponse)
async def weather(city_code: str = Query(default="110000", pattern=r"^\d{6}$")) -> WeatherResponse:
    try:
        return await get_weather(city_code)
    except ProviderUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/v1/travel/route", response_model=RouteResponse)
async def travel_route(payload: RouteRequest) -> RouteResponse:
    try:
        return await get_route(payload)
    except ProviderUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
