"""Payload validation: every endpoint declares its fields; unknown keys, wrong types and out-of-range values are
refused with error "bad-request" and a detail that names the field.

Booleans must be JSON true/false (not 0/1); integers must be JSON integers (a bool is not an int); numbers may be
integers or finite floats; null is never accepted (leave the key out to get the default).
"""

from __future__ import annotations

import math
from typing import Any, Callable

MISSING = object()


class BadRequest(Exception):
    word = "bad-request"

    def __init__(self, detail: str):
        super().__init__(detail)
        self.detail = detail


class Field:
    def __init__(self, kind: str, default: Any = MISSING, lo: float | None = None, hi: float | None = None,
                 choices: tuple | None = None, check: Callable[[Any], str | None] | None = None):
        self.kind = kind          # "int", "num", "bool", "str"
        self.default = default    # MISSING: required
        self.lo = lo              # int/num: range; str: length range
        self.hi = hi
        self.choices = choices
        self.check = check        # extra check: returns a reason or None


def Int(default=MISSING, lo=None, hi=None, check=None) -> Field:
    return Field("int", default, lo, hi, check=check)


def Num(default=MISSING, lo=None, hi=None) -> Field:
    return Field("num", default, lo, hi)


def Bool(default=MISSING) -> Field:
    return Field("bool", default)


def Str(default=MISSING, lo=None, hi=None, choices=None, check=None) -> Field:
    return Field("str", default, lo, hi, choices=choices, check=check)


def _range(name: str, value, lo, hi, unit: str = "") -> None:
    if lo is not None and value < lo or hi is not None and value > hi:
        if lo is not None and hi is not None:
            raise BadRequest(f"{name} must be {unit}between {lo:g} and {hi:g}")
        if lo is not None:
            raise BadRequest(f"{name} must be {unit}at least {lo:g}")
        raise BadRequest(f"{name} must be {unit}at most {hi:g}")


def validate(payload: Any, fields: dict[str, Field]) -> dict:
    """Check `payload` against `fields`; return the values with defaults filled in."""
    if not isinstance(payload, dict):
        raise BadRequest("the body must be a JSON object")
    unknown = sorted(k for k in payload if k not in fields)
    if unknown:
        allowed = ", ".join(fields) or "none"
        raise BadRequest(f"unknown field {unknown[0]!r} (allowed: {allowed})")
    out = {}
    for name, f in fields.items():
        value = payload.get(name, MISSING)
        if value is MISSING:
            if f.default is MISSING:
                raise BadRequest(f"{name} is required")
            out[name] = f.default
            continue
        if value is None:
            raise BadRequest(f"{name} must not be null (leave it out for the default)")
        if f.kind == "bool":
            if not isinstance(value, bool):
                raise BadRequest(f"{name} must be true or false")
        elif f.kind == "int":
            if isinstance(value, bool) or not isinstance(value, int):
                raise BadRequest(f"{name} must be an integer")
            _range(name, value, f.lo, f.hi)
        elif f.kind == "num":
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise BadRequest(f"{name} must be a number")
            if isinstance(value, float) and not math.isfinite(value):
                raise BadRequest(f"{name} must be a finite number")
            _range(name, value, f.lo, f.hi)
        elif f.kind == "str":
            if not isinstance(value, str):
                raise BadRequest(f"{name} must be a string")
            if f.choices is not None and value not in f.choices:
                raise BadRequest(f"{name} must be one of {', '.join(f.choices)}")
            if f.lo is not None and len(value) < f.lo or f.hi is not None and len(value) > f.hi:
                if f.lo is not None and f.hi is not None:
                    raise BadRequest(f"{name} must be {f.lo} to {f.hi} characters long")
                if f.lo is not None:
                    raise BadRequest(f"{name} must be at least {f.lo} characters long")
                raise BadRequest(f"{name} must be at most {f.hi} characters long")
        else:   # pragma: no cover - a programming error
            raise AssertionError(f"unknown field kind {f.kind}")
        if f.check is not None:
            reason = f.check(value)
            if reason:
                raise BadRequest(reason if reason.startswith(name) else f"{name}: {reason}")
        out[name] = value
    return out
