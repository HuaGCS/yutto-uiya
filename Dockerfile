# 多阶段构建，支持 yutto 自动更新
FROM python:3.11-slim

# 设置维护者信息和标签
LABEL maintainer="user" \
      description="yutto-uiya with auto-updating yutto" \
      version="1.0.0"

# 构建参数
ARG VERSION=latest
ARG BUILD_DATE
ARG ENVIRONMENT=production

# 设置环境变量
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VERSION=${VERSION} \
    ENVIRONMENT=${ENVIRONMENT} \
    YUTTO_AUTO_UPDATE=true \
    YUTTO_UPDATE_INTERVAL=3600 \
    YUTTO_IDLE_TIME=1800

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    ffmpeg \
    git \
    curl \
    supervisor \
    procps \
    && rm -rf /var/lib/apt/lists/*

# 配置 pip 使用国内镜像源（可选，国内用户推荐）
#RUN pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple

# 安装 uv 包管理器
RUN pip install uv

# 创建非 root 用户
RUN groupadd -r yutto && useradd -r -g yutto -s /bin/bash yutto

# 设置工作目录
WORKDIR /app

# 复制项目文件
COPY . .

# 如果在国内，修改 pyproject.toml 使用国内源
#RUN if [ -f pyproject.toml ]; then \
#        sed -i 's|python-install-mirror = "https://github.com/astral-sh/python-build-standalone/releases/download"|python-install-mirror = "https://mirror.nju.edu.cn/github-release/indygreg/python-build-standalone/"|g' pyproject.toml && \
#        sed -i 's|# name = "tsinghua"|name = "tsinghua"|g' pyproject.toml && \
#        sed -i 's|# url = "https://pypi.tuna.tsinghua.edu.cn/simple"|url = "https://pypi.tuna.tsinghua.edu.cn/simple"|g' pyproject.toml && \
#        sed -i 's|# default = true|default = true|g' pyproject.toml && \
#        sed -i 's|name = "pypi"|# name = "pypi"|g' pyproject.toml && \
#        sed -i 's|url = "https://pypi.org/simple"|# url = "https://pypi.org/simple"|g' pyproject.toml && \
#        sed -i 's|default= true|# default= true|g' pyproject.toml; \
#    fi

# 安装 yutto 和其他依赖
RUN pip install yutto streamlit

# 使用 uv 安装项目依赖
RUN uv lock || echo "Lock file generation failed, continuing..." && \
    uv sync || echo "Sync failed, trying alternative installation method..."

# 创建 yutto 智能更新脚本
RUN cat > /usr/local/bin/yutto-updater.sh << 'UPDATER_EOF'
#!/bin/bash

# yutto 智能更新脚本
LOG_FILE="/var/log/yutto-updater.log"
LOCK_FILE="/tmp/yutto-update.lock"
ACTIVITY_FILE="/tmp/yutto-activity"
UPDATE_INTERVAL=${YUTTO_UPDATE_INTERVAL:-3600}

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_yutto_activity() {
    # 检查 yutto 进程是否在运行
    if pgrep -f "yutto" > /dev/null; then
        log_message "检测到 yutto 进程运行中，跳过更新"
        return 1
    fi

    # 检查最近是否有下载活动
    if [ -f "$ACTIVITY_FILE" ]; then
        local last_activity=$(stat -c %Y "$ACTIVITY_FILE" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local idle_time=$((current_time - last_activity))
        local idle_threshold=${YUTTO_IDLE_TIME:-1800}

        if [ $idle_time -lt $idle_threshold ]; then
            log_message "检测到 $((idle_threshold/60)) 分钟内有下载活动，延迟更新 (空闲时间: $((idle_time/60)) 分钟)"
            return 1
        fi
    fi

    return 0
}

update_yutto() {
    # 防止并发更新
    if [ -f "$LOCK_FILE" ]; then
        local lock_age=$(($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)))
        if [ $lock_age -lt 3600 ]; then
            log_message "更新锁定文件存在，跳过更新"
            return
        else
            rm -f "$LOCK_FILE"
        fi
    fi

    touch "$LOCK_FILE"

    # 获取当前版本
    local current_version=$(pip show yutto 2>/dev/null | grep "Version:" | cut -d' ' -f2 || echo "unknown")

    # 检查最新版本
    local latest_version
    latest_version=$(pip index versions yutto 2>/dev/null | head -n1 | awk '{print $2}' || echo "unknown")

    if [ "$current_version" = "$latest_version" ] || [ "$latest_version" = "unknown" ]; then
        log_message "yutto 已是最新版本: $current_version"
        rm -f "$LOCK_FILE"
        return
    fi

    log_message "发现 yutto 新版本: $current_version -> $latest_version"

    # 检查是否空闲
    if ! check_yutto_activity; then
        rm -f "$LOCK_FILE"
        return
    fi

    # 执行更新
    log_message "开始更新 yutto ($current_version -> $latest_version)..."

    if pip install --upgrade yutto 2>&1 | tee -a "$LOG_FILE"; then
        local new_version=$(pip show yutto | grep "Version:" | cut -d' ' -f2)
        log_message "✅ yutto 更新成功: $new_version"

        # 记录更新完成时间
        echo "$(date +%s)" > /tmp/yutto-last-update

        # 通知 Web 界面（可选）
        if command -v curl > /dev/null 2>&1; then
            curl -s -X POST "http://localhost:8501/_yutto_updated" \
                -H "Content-Type: application/json" \
                -d "{\"old_version\":\"$current_version\",\"new_version\":\"$new_version\"}" \
                > /dev/null 2>&1 || true
        fi
    else
        log_message "❌ yutto 更新失败"
    fi

    rm -f "$LOCK_FILE"
}

# 主循环
main() {
    log_message "🚀 yutto 自动更新守护程序启动"
    log_message "📋 配置信息:"
    log_message "   - 自动更新: ${YUTTO_AUTO_UPDATE:-true}"
    log_message "   - 检查间隔: ${UPDATE_INTERVAL} 秒 ($((UPDATE_INTERVAL/60)) 分钟)"
    log_message "   - 空闲阈值: ${YUTTO_IDLE_TIME:-1800} 秒 ($((${YUTTO_IDLE_TIME:-1800}/60)) 分钟)"

    # 启动时检查一次
    if [ "${YUTTO_AUTO_UPDATE:-true}" = "true" ]; then
        update_yutto
    fi

    while true; do
        if [ "${YUTTO_AUTO_UPDATE:-true}" = "true" ]; then
            update_yutto
        fi
        sleep $UPDATE_INTERVAL
    done
}

# 如果直接执行脚本
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
UPDATER_EOF

# 创建增强的 Streamlit 启动脚本
RUN cat > /usr/local/bin/enhanced-streamlit.py << 'STREAMLIT_EOF'
#!/usr/bin/env python3
import streamlit as st
import subprocess
import time
import os
from datetime import datetime
import json

# 记录活动时间的函数
def record_activity():
    """记录用户活动时间，用于更新策略判断"""
    try:
        activity_file = "/tmp/yutto-activity"
        with open(activity_file, 'w') as f:
            f.write(str(int(time.time())))
    except:
        pass

def get_yutto_info():
    """获取 yutto 版本和状态信息"""
    try:
        result = subprocess.run(['pip', 'show', 'yutto'],
                              capture_output=True, text=True, check=True)
        version = "unknown"
        for line in result.stdout.split('\n'):
            if line.startswith('Version:'):
                version = line.split(':', 1)[1].strip()
                break

        # 检查最新版本
        try:
            latest_result = subprocess.run(['pip', 'index', 'versions', 'yutto'],
                                         capture_output=True, text=True, timeout=10)
            latest_version = "unknown"
            if latest_result.returncode == 0:
                lines = latest_result.stdout.strip().split('\n')
                if lines:
                    latest_version = lines[0].split()[1] if len(lines[0].split()) > 1 else "unknown"
        except:
            latest_version = "unknown"

        return {
            'current': version,
            'latest': latest_version,
            'update_available': latest_version != "unknown" and version != latest_version and latest_version != version
        }
    except:
        return {'current': 'unknown', 'latest': 'unknown', 'update_available': False}

def get_update_status():
    """获取自动更新状态"""
    auto_update = os.getenv('YUTTO_AUTO_UPDATE', 'true').lower() == 'true'
    update_interval = int(os.getenv('YUTTO_UPDATE_INTERVAL', '3600'))
    idle_time = int(os.getenv('YUTTO_IDLE_TIME', '1800'))

    return {
        'enabled': auto_update,
        'interval_minutes': update_interval // 60,
        'idle_minutes': idle_time // 60
    }

def show_version_sidebar():
    """在侧边栏显示版本和更新信息"""
    with st.sidebar:
        st.markdown("---")
        st.markdown("### 🔧 系统状态")

        # 获取 yutto 信息
        yutto_info = get_yutto_info()
        update_status = get_update_status()

        # 显示版本信息
        col1, col2 = st.columns([1, 1])
        with col1:
            st.markdown("**yutto 版本**")
        with col2:
            if yutto_info['update_available']:
                st.markdown(f"🆕 `{yutto_info['current']}`")
            else:
                st.markdown(f"✅ `{yutto_info['current']}`")

        # 显示更新状态
        if update_status['enabled']:
            st.success(f"🔄 自动更新已启用")
            st.caption(f"每 {update_status['interval_minutes']} 分钟检查，{update_status['idle_minutes']} 分钟空闲后更新")
        else:
            st.warning("⚠️ 自动更新已禁用")

        # 更新信息和操作
        if yutto_info['update_available'] and yutto_info['latest'] != 'unknown':
            st.info(f"📢 新版本可用: `{yutto_info['latest']}`")

        # 手动检查按钮
        col1, col2 = st.columns([1, 1])
        with col1:
            if st.button("🔍 检查", key="check_update", help="检查 yutto 更新"):
                record_activity()
                st.rerun()

        with col2:
            if st.button("📊 日志", key="view_logs", help="查看更新日志"):
                try:
                    with open("/var/log/yutto-updater.log", "r") as f:
                        logs = f.read().split('\n')[-10:]  # 最后10行
                    st.text_area("最近更新日志", "\n".join(logs), height=200, key="update_logs")
                except:
                    st.error("无法读取更新日志")

# 这个函数会在每次页面加载时调用
record_activity()

# 运行原始应用前先显示版本信息
show_version_sidebar()

# 寻找并运行原始的 yutto_uiya.py
original_script_paths = [
    "/app/src/uiya/yutto_uiya.py",
    "/app/yutto_uiya.py",
    "/app/src/yutto_uiya.py"
]

original_script = None
for path in original_script_paths:
    if os.path.exists(path):
        original_script = path
        break

if original_script:
    # 设置 Python 路径
    import sys
    sys.path.insert(0, os.path.dirname(original_script))
    sys.path.insert(0, '/app/src')

    try:
        # 执行原始脚本
        with open(original_script, 'r', encoding='utf-8') as f:
            code = f.read()
        exec(code, {'__file__': original_script})
    except Exception as e:
        st.error(f"启动 yutto-uiya 应用时出错: {str(e)}")
        st.info("请检查项目文件结构是否正确")
else:
    st.error("❌ 找不到 yutto_uiya.py 文件")
    st.info("请确保项目文件结构正确")
    st.markdown("尝试查找的路径:")
    for path in original_script_paths:
        st.code(path)
STREAMLIT_EOF

# 创建 supervisor 配置
RUN mkdir -p /etc/supervisor/conf.d && \
    cat > /etc/supervisor/conf.d/yutto-services.conf << 'SUPERVISOR_EOF'
[program:yutto-updater]
command=/bin/bash /usr/local/bin/yutto-updater.sh
user=yutto
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/yutto-updater.log
environment=YUTTO_AUTO_UPDATE="%(ENV_YUTTO_AUTO_UPDATE)s",YUTTO_UPDATE_INTERVAL="%(ENV_YUTTO_UPDATE_INTERVAL)s",YUTTO_IDLE_TIME="%(ENV_YUTTO_IDLE_TIME)s"

[program:streamlit]
command=python /usr/local/bin/enhanced-streamlit.py
directory=/app
user=yutto
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/streamlit.log
environment=PYTHONPATH="/app:/app/src",HOME="/home/yutto"
SUPERVISOR_EOF

# 设置权限和目录
RUN chmod +x /usr/local/bin/yutto-updater.sh && \
    chmod +x /usr/local/bin/enhanced-streamlit.py && \
    mkdir -p /var/log /app/downloads /app/config /home/yutto && \
    touch /var/log/yutto-updater.log /var/log/streamlit.log && \
    chown -R yutto:yutto /app /var/log/yutto-updater.log /var/log/streamlit.log /tmp /home/yutto

# 创建启动脚本
RUN cat > /usr/local/bin/start-services.sh << 'START_EOF'
#!/bin/bash

echo "🚀 启动 yutto-uiya 增强版 (支持 yutto 自动更新)..."
echo "📋 配置信息:"
echo "   🔄 自动更新: ${YUTTO_AUTO_UPDATE:-true}"
echo "   ⏰ 更新间隔: ${YUTTO_UPDATE_INTERVAL:-3600} 秒 ($((${YUTTO_UPDATE_INTERVAL:-3600}/60)) 分钟)"
echo "   💤 空闲阈值: ${YUTTO_IDLE_TIME:-1800} 秒 ($((${YUTTO_IDLE_TIME:-1800}/60)) 分钟)"
echo "   🌐 Web 端口: 8501"
echo "   📁 下载目录: /app/downloads"

# 确保日志目录存在且有正确权限
mkdir -p /var/log
touch /var/log/yutto-updater.log /var/log/streamlit.log
chown yutto:yutto /var/log/yutto-updater.log /var/log/streamlit.log

# 启动 supervisor
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
START_EOF

RUN chmod +x /usr/local/bin/start-services.sh

# 暴露端口
EXPOSE 8501

# 设置时区
ENV TZ=Asia/Shanghai

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8501/_stcore/health || exit 1

# 使用 supervisor 启动所有服务
CMD ["/usr/local/bin/start-services.sh"]
