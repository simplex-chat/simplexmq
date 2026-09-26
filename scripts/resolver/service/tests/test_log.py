import io
import json
import logging
import re
import unittest

from snrc_resolve import config, log

TIME = r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"


class LogTestCase(unittest.TestCase):
    def setUp(self):
        self._saved = (config.LOG_FORMAT, config.LOG_COLOR, config.LOG_LEVEL)
        config.LOG_FORMAT, config.LOG_COLOR, config.LOG_LEVEL = "text", "never", "info"
        self.out = io.StringIO()

    def tearDown(self):
        config.LOG_FORMAT, config.LOG_COLOR, config.LOG_LEVEL = self._saved
        log.LOGGER.handlers[:] = []
        log.LOGGER.setLevel(logging.NOTSET)
        log.LOGGER.propagate = True

    def emit(self, level=logging.INFO, name="request", **fields):
        log.setup(self.out)
        log.event(level, name, **fields)
        return self.out.getvalue()


class TextFormatTests(LogTestCase):
    def test_a_line_is_utc_time_level_event_and_fields(self):
        line = self.emit(client="203.0.113.7", path="/v2/resolve/[4fdd].testing", status=200, ms=7)
        self.assertRegex(line, rf"^{TIME} INFO  request  client=203\.0\.113\.7 path=/v2/resolve/\[4fdd\]\.testing status=200 ms=7\n$")

    def test_values_that_would_be_misread_are_quoted(self):
        line = self.emit(message='says "hi" here', empty="", missing=None, eq="a=b")
        self.assertIn('message="says \\"hi\\" here" empty="" missing=- eq="a=b"', line)

    def test_levels_are_named_in_five_columns(self):
        self.assertRegex(self.emit(logging.WARNING, "upstream_error"), rf"^{TIME} WARN  upstream_error\n$")

    def test_below_the_configured_level_nothing_is_written(self):
        self.assertEqual(self.emit(logging.DEBUG), "")

    def test_an_exception_follows_its_line(self):
        log.setup(self.out)
        try:
            raise KeyError("boom")
        except KeyError:
            log.event(logging.ERROR, "request_failed", exc_info=True)
        self.assertRegex(self.out.getvalue(), rf"(?s)^{TIME} ERROR request_failed\nTraceback .*KeyError: 'boom'\n$")


class ColorTests(LogTestCase):
    def test_colours_mark_the_level_and_the_status_class(self):
        config.LOG_COLOR = "always"
        line = self.emit(status=503)
        self.assertIn("\033[32mINFO ", line)
        self.assertIn("\033[31m503\033[0m", line)

    def test_auto_leaves_output_that_is_no_terminal_plain(self):
        config.LOG_COLOR = "auto"
        self.assertNotIn("\033[", self.emit(status=200))

    def test_never_is_plain(self):
        self.assertNotIn("\033[", self.emit(status=200))


class JsonFormatTests(LogTestCase):
    def test_a_line_is_one_json_object(self):
        config.LOG_FORMAT = "json"
        record = json.loads(self.emit(client="203.0.113.7", status=200, missing=None))
        self.assertRegex(record.pop("time"), rf"^{TIME}$")
        self.assertEqual(record, {"level": "info", "event": "request", "client": "203.0.113.7", "status": 200, "missing": None})

    def test_an_exception_is_a_field(self):
        config.LOG_FORMAT = "json"
        log.setup(self.out)
        try:
            raise KeyError("boom")
        except KeyError:
            log.event(logging.ERROR, "request_failed", exc_info=True)
        self.assertIn("KeyError: 'boom'", json.loads(self.out.getvalue())["exception"])


class SetupTests(LogTestCase):
    def test_unknown_settings_are_refused_at_start(self):
        for setting, value in (("LOG_FORMAT", "yaml"), ("LOG_COLOR", "sometimes"), ("LOG_LEVEL", "loud")):
            with self.subTest(setting=setting):
                saved = getattr(config, setting)
                setattr(config, setting, value)
                try:
                    with self.assertRaisesRegex(ValueError, re.escape(f"SNRC_{setting}")):
                        log.setup(self.out)
                finally:
                    setattr(config, setting, saved)
