"""Structured JSON logging.

One line of JSON per event so the CloudWatch metric filter in
infrastructure/terraform/modules/observability can match on {$.level = "ERROR"} without
regex-parsing free text. Stdlib only -- a log formatter is not worth a dependency.
"""

import json
import logging
import sys
from datetime import datetime, timezone

_RESERVED = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "asctime",
    "message",
    "taskName",
}


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str, env: str) -> None:
        super().__init__()
        self.service = service
        self.env = env

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.fromtimestamp(
                record.created, tz=timezone.utc
            ).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "service": self.service,
            "env": self.env,
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        # Anything passed via logger.info("...", extra={...}) rides along.
        payload.update({k: v for k, v in record.__dict__.items() if k not in _RESERVED})
        return json.dumps(payload, default=str)


def configure_logging(service: str, env: str, level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service, env))

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())

    # uvicorn installs its own handlers; force them through ours so access logs
    # are JSON too and land in the same CloudWatch stream.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logger = logging.getLogger(name)
        logger.handlers = []
        logger.propagate = True
