"""Version reporting: pyproject.toml is the single source of truth.

Regression guard: `__version__` was hardcoded in cleaner.py and went five
releases stale (stuck at 1.2.0 while releases shipped 1.7.1), so `--version`
and the `--summary` JSON both reported a wrong number.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

import cleaner

PYPROJECT = Path(__file__).parent.parent / "pyproject.toml"


def _pyproject_version():
    """Read the shipped version without going through cleaner.py's own code."""
    text = PYPROJECT.read_text(encoding="utf-8")
    m = re.search(r'^\s*version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    assert m, "pyproject.toml has no version literal"
    return m.group(1)


def test_version_matches_pyproject():
    """The CLI must report the version that actually shipped."""
    assert cleaner.__version__ == _pyproject_version()


def test_version_is_not_unknown():
    """In a checkout, pyproject.toml is reachable, so the fallback must not fire."""
    assert cleaner.__version__ != "unknown"


def test_summary_json_reports_same_version(tmp_path):
    """End-to-end: the --summary JSON field agents parse carries the real version."""
    src = tmp_path / "sample.txt"
    src.write_text("hello\n", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(PYPROJECT.parent / "cleaner.py"),
         "--input", str(src), "--ai", "none",
         "--output-dir", str(tmp_path / "out"), "--summary"],
        capture_output=True, text=True, timeout=180,
    )
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout.strip().splitlines()[-1])
    assert payload["version"] == _pyproject_version()


def test_regex_fallback_agrees_with_tomllib():
    """The 3.9/3.10 path must return what the tomllib path returns."""
    text = PYPROJECT.read_text(encoding="utf-8")
    assert cleaner._extract_version_regex(text) == cleaner._extract_version(text)


def test_regex_fallback_returns_none_without_version():
    assert cleaner._extract_version_regex('[tool.briefcase]\nname = "x"\n') is None


def test_extract_version_falls_back_on_malformed_toml():
    """Malformed TOML still yields a version rather than raising."""
    text = '[tool.briefcase\nversion = "9.9.9"\n'  # unclosed table header
    assert cleaner._extract_version(text) == "9.9.9"


def test_extract_version_none_when_absent():
    assert cleaner._extract_version("[tool.other]\nfoo = 1\n") is None


def test_read_version_unknown_when_pyproject_missing(monkeypatch):
    """No pyproject.toml (file copied out standalone) must not report a number."""
    monkeypatch.setattr(cleaner, "__file__", "/nonexistent/dir/cleaner.py")
    assert cleaner._read_version() == "unknown"
