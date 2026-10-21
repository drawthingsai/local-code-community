FROM python:3.11.9-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/livecodebench

RUN python -m pip install --no-cache-dir \
    numpy==2.1.3 \
    pandas==2.2.3 \
    tqdm==4.67.1

WORKDIR /opt/livecodebench
COPY lcb_runner ./lcb_runner

ENTRYPOINT ["python", "/runner/score.py"]
