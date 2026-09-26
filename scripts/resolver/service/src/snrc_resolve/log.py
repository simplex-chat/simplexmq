"""Log lines: one per event, as key=value text (coloured on a terminal) or as JSON."""

import json
import logging
import sys
from datetime import datetime, timezone

from . import config

LOGGER = logging.getLogger("snrc_resolve")
LEVEL_NAMES = {logging.DEBUG: "DEBUG", logging.INFO: "INFO", logging.WARNING: "WARN", logging.ERROR: "ERROR"}
# ANSI SGR codes
DIM, BOLD, GREEN, YELLOW, RED = "2", "1", "32", "33", "31"
LEVEL_COLORS = {"DEBUG": DIM, "INFO": GREEN, "WARN": YELLOW, "ERROR": RED}
STATUS_COLORS = {2: GREEN, 3: GREEN, 4: YELLOW, 5: RED}


def event(level: int, name: str, /, exc_info=None, **fields):
    LOGGER.log(level, name, exc_info=exc_info, extra={"fields": fields})


def _time(record: logging.LogRecord) -> str:
    return datetime.fromtimestamp(record.created, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _value(value) -> str:
    """A logfmt value: bare when it cannot be misread, JSON-quoted otherwise."""
    if value is None:
        return "-"
    s = str(value)
    if not s or any(c in s for c in ' ="\\') or not s.isprintable():
        return json.dumps(s)
    return s


class TextFormatter(logging.Formatter):
    def __init__(self, color: bool):
        super().__init__()
        self.color = color

    def _paint(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.color and code else text

    def format(self, record: logging.LogRecord) -> str:
        level = LEVEL_NAMES.get(record.levelno, record.levelname)
        fields = " ".join(
            self._paint(DIM, f"{k}=") + self._paint(STATUS_COLORS.get(v // 100, "") if k == "status" and isinstance(v, int) else "", _value(v))
            for k, v in getattr(record, "fields", {}).items()
        )
        line = f"{self._paint(DIM, _time(record))} {self._paint(LEVEL_COLORS.get(level, ''), f'{level:<5}')} {self._paint(BOLD, record.getMessage())}"
        if fields:
            line += "  " + fields
        if record.exc_info:
            line += "\n" + self.formatException(record.exc_info)
        return line


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        out = {
            "time": _time(record),
            "level": LEVEL_NAMES.get(record.levelno, record.levelname).lower(),
            "event": record.getMessage(),
            **getattr(record, "fields", {}),
        }
        if record.exc_info:
            out["exception"] = self.formatException(record.exc_info)
        return json.dumps(out, default=str)


def setup(stream=None):
    """Sends the resolver's events to stderr in the configured format."""
    stream = stream or sys.stderr
    if config.LOG_FORMAT not in ("text", "json"):
        raise ValueError(f"SNRC_LOG_FORMAT must be text or json, not {config.LOG_FORMAT!r}")
    if config.LOG_COLOR not in ("auto", "always", "never"):
        raise ValueError(f"SNRC_LOG_COLOR must be auto, always or never, not {config.LOG_COLOR!r}")
    level = logging.getLevelName(config.LOG_LEVEL.upper())
    if not isinstance(level, int):
        raise ValueError(f"SNRC_LOG_LEVEL must be debug, info, warning or error, not {config.LOG_LEVEL!r}")
    color = config.LOG_COLOR == "always" or (config.LOG_COLOR == "auto" and stream.isatty())
    handler = logging.StreamHandler(stream)
    handler.setFormatter(JsonFormatter() if config.LOG_FORMAT == "json" else TextFormatter(color))
    LOGGER.handlers[:] = [handler]
    LOGGER.setLevel(level)
    LOGGER.propagate = False
