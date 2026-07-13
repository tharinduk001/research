FROM python:3.13.3-bookworm

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN useradd -m appuser
USER appuser

EXPOSE 8000

CMD ["sh", "-c", "python manage.py makemigrations --noinput && python manage.py migrate --noinput && gunicorn simply.wsgi:application --bind 0.0.0.0:8000 --workers 3 --threads 6 --timeout 30 --worker-class gthread"]