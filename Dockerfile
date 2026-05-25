FROM python@sha256:090ba77e2958f6af52a5341f788b50b032dd4ca28377d2893dcf1ecbdfdfe203

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Non-root runtime user.
RUN groupadd --system appgroup && \
    useradd --system --gid appgroup --create-home --home-dir /home/appuser appuser

WORKDIR /app

# Install Python dependencies first to maximize layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy only the application package.
COPY app/ ./app/

# Drop privileges.
RUN chown -R appuser:appgroup /app
USER appuser

EXPOSE 5000

# urllib-based healthcheck — no curl/wget dependency in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=4).status==200 else 1)" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "2", "--timeout", "30", "app.main:create_app()"]
