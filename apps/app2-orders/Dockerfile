FROM python:3.12-slim AS base

RUN groupadd -r appuser && useradd -r -g appuser appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN chown -R appuser:appuser /app
USER appuser

ARG APP_VERSION=unknown
ENV APP_VERSION=${APP_VERSION}
ENV PORT=5002

EXPOSE 5002

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5002/health')"

CMD ["gunicorn", "--bind", "0.0.0.0:5002", "--workers", "2", "--timeout", "30", "app:app"]
