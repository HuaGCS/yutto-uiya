# 使用 Python 3.11 官方镜像作为基础镜像
FROM python:3.11-slim

# 设置维护者信息
LABEL maintainer="user" \
      description="Docker image for yutto-uiya - bilibili video downloader with Streamlit WebUI"

# 设置环境变量
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    ffmpeg \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 配置 pip 使用国内镜像源（可选，国内用户推荐）
RUN pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple

# 安装 uv 包管理器
RUN pip install uv

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

# 先安装 yutto 核心库（这是 yutto-uiya 的基础依赖）
RUN pip install yutto

# 使用 uv 安装项目依赖
# 如果项目有 pyproject.toml，uv 会自动处理依赖关系
RUN uv lock || echo "Lock file generation failed, continuing..." && \
    uv sync || echo "Sync failed, trying alternative installation method..." && \
    uv pip install streamlit || pip install streamlit

# 确保必要的依赖都已安装
RUN pip install streamlit yutto

# 创建非 root 用户
RUN groupadd -r yutto && useradd -r -g yutto yutto

# 创建必要的目录
RUN mkdir -p /app/downloads /app/config && \
    chown -R yutto:yutto /app

# 切换到非 root 用户
USER yutto

# 暴露端口
EXPOSE 8501

# 设置时区
ENV TZ=Asia/Shanghai

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8501/_stcore/health || exit 1

# 启动命令 - 使用多种方式尝试启动应用
CMD if [ -f "src/uiya/yutto_uiya.py" ]; then \
        uv run streamlit run src/uiya/yutto_uiya.py --server.address 0.0.0.0 --server.port 8501; \
    else \
        streamlit run src/uiya/yutto_uiya.py --server.address 0.0.0.0 --server.port 8501; \
    fi
