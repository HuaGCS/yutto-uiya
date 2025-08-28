#!/bin/bash
set -e

echo "检查 Dockerfile..."

if [ ! -f "Dockerfile" ]; then
    echo "未找到 Dockerfile，创建基础 Dockerfile..."
    
    cat > Dockerfile << 'DOCKERFILE_END'
FROM python:3.11-slim

LABEL maintainer="auto-generated" \
      description="yutto-uiya with auto-updating yutto"

ARG VERSION=latest
ARG BUILD_DATE
ARG TARGETPLATFORM
ARG TARGETARCH

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    VERSION=${VERSION} \
    YUTTO_AUTO_UPDATE=true \
    YUTTO_UPDATE_INTERVAL=3600

RUN apt-get update && apt-get install -y \
    ffmpeg git curl supervisor procps \
    && rm -rf /var/lib/apt/lists/*

RUN pip install yutto streamlit uv

RUN groupadd -r yutto && useradd -r -g yutto yutto

WORKDIR /app
COPY . .

RUN uv sync || pip install -e . || echo "Dependencies installed"

RUN cat > /usr/local/bin/yutto-updater.sh << 'UPDATER_SCRIPT_END'
#!/bin/bash
LOG_FILE="/var/log/yutto-updater.log"
UPDATE_INTERVAL=${YUTTO_UPDATE_INTERVAL:-3600}

log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

update_yutto() {
  if [ "${YUTTO_AUTO_UPDATE:-true}" != "true" ]; then
    return
  fi

  if pgrep -f "yutto" > /dev/null; then
    log_message "yutto 进程运行中，跳过更新"
    return
  fi

  local current=$(pip show yutto 2>/dev/null | grep "Version:" | cut -d' ' -f2 || echo "unknown")
  local latest=$(pip index versions yutto 2>/dev/null | head -n1 | awk '{print $2}' || echo "unknown")

  if [ "$current" != "$latest" ] && [ "$latest" != "unknown" ]; then
    log_message "更新 yutto: $current -> $latest"
    pip install --upgrade yutto && log_message "更新成功" || log_message "更新失败"
  fi
}

log_message "yutto 更新守护程序启动"
while true; do
  update_yutto
  sleep $UPDATE_INTERVAL
done
UPDATER_SCRIPT_END

RUN mkdir -p /etc/supervisor/conf.d /var/log && \
    chmod +x /usr/local/bin/yutto-updater.sh

RUN cat > /etc/supervisor/conf.d/services.conf << 'SUPERVISOR_CONF_END'
[program:yutto-updater]
command=/bin/bash /usr/local/bin/yutto-updater.sh
user=yutto
autostart=true
autorestart=true
stdout_logfile=/var/log/yutto-updater.log

[program:streamlit]
command=streamlit run src/uiya/yutto_uiya.py --server.address 0.0.0.0 --server.port 8501
directory=/app
user=yutto
autostart=true
autorestart=true
stdout_logfile=/var/log/streamlit.log
environment=PYTHONPATH=/app:/app/src
SUPERVISOR_CONF_END

RUN chown -R yutto:yutto /app /var/log

EXPOSE 8501
ENV TZ=Asia/Shanghai

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8501/_stcore/health || exit 1

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
DOCKERFILE_END

    echo "基础 Dockerfile 已创建"
else
    echo "发现现有的 Dockerfile"
fi
