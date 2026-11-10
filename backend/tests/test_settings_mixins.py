"""``Settings`` is built from mixins; a method or validator name defined in two of them silently
shadows the other (pydantic keeps one per name), which once disabled a key check. Pure."""

from __future__ import annotations

import inspect
from collections import defaultdict

from app.config import Settings


def callables_by_name() -> dict[str, list[str]]:
    owners: dict[str, list[str]] = defaultdict(list)
    for cls in Settings.__mro__:
        if not cls.__module__.startswith("app."):
            continue  # pydantic, pydantic-settings and ``object`` are not ours
        for name, value in vars(cls).items():
            if name.startswith("__"):
                continue
            wrapped = getattr(value, "__func__", value)
            if inspect.isfunction(wrapped) or isinstance(value, property):
                owners[name].append(cls.__name__)
    return owners


def test_the_guard_sees_the_mixins_and_their_validators() -> None:
    owners = callables_by_name()
    assert "PaymentSettings" in owners["payments_key_bytes"]
    assert "Settings" in owners["_prod_safety"]
    assert owners["_payments_key_is_32_bytes"] == ["PaymentSettings"]


def test_no_method_or_validator_name_is_defined_in_two_classes_of_settings() -> None:
    clashes = {name: who for name, who in callables_by_name().items() if len(who) > 1}
    assert not clashes, f"rename one of each pair: {clashes}"
