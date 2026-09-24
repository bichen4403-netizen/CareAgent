FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app

# 不以 root 运行
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8000
# 密钥通过 docker run --env-file .env 注入，不打进镜像
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
