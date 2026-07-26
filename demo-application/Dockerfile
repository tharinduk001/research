FROM python:3.13.3-bookworm

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN useradd -m appuser
USER appuser

EXPOSE 8000

# NOTE: --workers 1 is deliberate, do not raise it without reading this.
# django-prometheus keeps its counters in process memory. With multiple gunicorn
# workers each worker has its OWN independent counters, and /metrics is served by
# whichever worker happens to answer the scrape. Prometheus then sees the value jump
# up and down, treats every drop as a counter reset, and rate() becomes garbage
# (measured: ~800x inflated). The alternative fix (PROMETHEUS_MULTIPROC_DIR) keeps
# multiple workers but drops process_* and python_gc_* from the registry, which are
# signals this project needs. At the observed load (~6 req/s per pod) one worker with
# 8 threads has ample headroom.
CMD ["sh", "-c", "python manage.py makemigrations --noinput && python manage.py migrate --noinput && gunicorn simply.wsgi:application --bind 0.0.0.0:8000 --workers 1 --threads 8 --timeout 30 --worker-class gthread"]