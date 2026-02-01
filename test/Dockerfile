FROM python:3.11-slim

WORKDIR /app

RUN pip install flask

COPY mock_upstream.py .

EXPOSE 80

# 设置健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:80').read()" || exit 1

CMD ["python", "mock_upstream.py"]