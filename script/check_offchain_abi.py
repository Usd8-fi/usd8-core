#!/usr/bin/env python3
"""Compare Rust's consumed first-party ABI subset with fresh Foundry artifacts."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class ParityError(RuntimeError):
    pass


@dataclass(frozen=True)
class AbiItem:
    kind: str
    name: str
    inputs: tuple[str, ...]
    outputs: tuple[str, ...] = ()
    state_mutability: str = ""
    indexed: tuple[bool, ...] = ()
    anonymous: bool = False

    @property
    def identity(self) -> str:
        return f"{self.kind}:{self.name}({','.join(self.inputs)})"


FIRST_PARTY = {
    "IDefiInsurance": ("DefiInsurance", "DefiInsurance.sol/DefiInsurance.json"),
    "IRegistry": ("Registry", "Registry.sol/Registry.json"),
    "ISingleAssetCoverPool": (
        "SingleAssetCoverPool",
        "SingleAssetCoverPool.sol/SingleAssetCoverPool.json",
    ),
}


def strip_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def named_block(source: str, keyword: str, name: str) -> str:
    match = re.search(rf"\b{re.escape(keyword)}\s+{re.escape(name)}\s*\{{", source)
    if match is None:
        raise ParityError(f"Rust ABI source missing {keyword} {name}")
    start = match.end()
    depth = 1
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index]
    raise ParityError(f"unterminated {keyword} {name}")


def split_parameters(value: str) -> list[str]:
    parts: list[str] = []
    start = 0
    depth = 0
    for index, char in enumerate(value):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(value[start:index].strip())
            start = index + 1
    tail = value[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def source_type(parameter: str, structs: dict[str, tuple[str, ...]]) -> str:
    tokens = [
        token
        for token in parameter.replace("\n", " ").split()
        if token not in {"calldata", "memory", "storage", "indexed", "payable"}
    ]
    if not tokens:
        raise ParityError(f"empty ABI parameter: {parameter!r}")
    type_name = tokens[0]
    match = re.fullmatch(r"([A-Za-z_]\w*)((?:\[[0-9]*\])*)", type_name)
    if match is None:
        return type_name
    base, suffix = match.groups()
    if base not in structs:
        return type_name
    return f"({','.join(structs[base])}){suffix}"


def source_structs(interface_body: str) -> dict[str, tuple[str, ...]]:
    structs: dict[str, tuple[str, ...]] = {}
    for match in re.finditer(r"\bstruct\s+([A-Za-z_]\w*)\s*\{", interface_body):
        name = match.group(1)
        body = named_block(interface_body[match.start() :], "struct", name)
        fields = [field.strip() for field in body.split(";") if field.strip()]
        # Structs in this authority use only primitive fields or earlier structs.
        structs[name] = tuple(source_type(field, structs) for field in fields)
    return structs


def source_items(interface_body: str) -> list[AbiItem]:
    structs = source_structs(interface_body)
    items: list[AbiItem] = []
    function_pattern = re.compile(
        r"\bfunction\s+([A-Za-z_]\w*)\s*\((.*?)\)\s*(.*?)\s*;", re.DOTALL
    )
    for match in function_pattern.finditer(interface_body):
        name, raw_inputs, modifiers = match.groups()
        returns = re.search(r"\breturns\s*\((.*?)\)", modifiers, flags=re.DOTALL)
        inputs = tuple(source_type(item, structs) for item in split_parameters(raw_inputs))
        outputs = (
            tuple(source_type(item, structs) for item in split_parameters(returns.group(1)))
            if returns
            else ()
        )
        state = next(
            (candidate for candidate in ("pure", "view", "payable") if re.search(rf"\b{candidate}\b", modifiers)),
            "nonpayable",
        )
        items.append(AbiItem("function", name, inputs, outputs, state_mutability=state))

    event_pattern = re.compile(
        r"\bevent\s+([A-Za-z_]\w*)\s*\((.*?)\)\s*(anonymous\s*)?;", re.DOTALL
    )
    for match in event_pattern.finditer(interface_body):
        name, raw_inputs, anonymous = match.groups()
        parameters = split_parameters(raw_inputs)
        items.append(
            AbiItem(
                "event",
                name,
                tuple(source_type(item, structs) for item in parameters),
                indexed=tuple(bool(re.search(r"\bindexed\b", item)) for item in parameters),
                anonymous=bool(anonymous),
            )
        )
    return items


def artifact_type(parameter: dict[str, Any]) -> str:
    type_name = parameter.get("type")
    if not isinstance(type_name, str):
        raise ParityError("artifact ABI parameter has no type")
    if not type_name.startswith("tuple"):
        return type_name
    components = parameter.get("components")
    if not isinstance(components, list):
        raise ParityError("artifact tuple has no components")
    suffix = type_name[len("tuple") :]
    return f"({','.join(artifact_type(component) for component in components)}){suffix}"


def artifact_items(abi: list[dict[str, Any]]) -> dict[str, AbiItem]:
    parsed: dict[str, AbiItem] = {}
    for raw in abi:
        kind = raw.get("type")
        if kind not in {"function", "event"}:
            continue
        name = raw.get("name")
        inputs_raw = raw.get("inputs")
        if not isinstance(name, str) or not isinstance(inputs_raw, list):
            raise ParityError("malformed artifact ABI item")
        inputs = tuple(artifact_type(item) for item in inputs_raw)
        if kind == "function":
            outputs_raw = raw.get("outputs")
            if not isinstance(outputs_raw, list):
                raise ParityError(f"artifact function {name} has no outputs")
            item = AbiItem(
                kind,
                name,
                inputs,
                tuple(artifact_type(output) for output in outputs_raw),
                state_mutability=str(raw.get("stateMutability", "")),
            )
        else:
            item = AbiItem(
                kind,
                name,
                inputs,
                indexed=tuple(bool(value.get("indexed", False)) for value in inputs_raw),
                anonymous=bool(raw.get("anonymous", False)),
            )
        if item.identity in parsed:
            raise ParityError(f"duplicate artifact ABI identity {item.identity}")
        parsed[item.identity] = item
    return parsed


def assert_subset(label: str, expected: list[AbiItem], artifact: list[dict[str, Any]]) -> int:
    actual = artifact_items(artifact)
    checked = 0
    for item in expected:
        found = actual.get(item.identity)
        if found is None:
            raise ParityError(f"{label} ABI missing {item.identity}")
        if item.kind == "function":
            if item.outputs != found.outputs:
                raise ParityError(
                    f"{label} {item.identity} outputs mismatch: Rust {item.outputs}, artifact {found.outputs}"
                )
            if item.state_mutability != found.state_mutability:
                raise ParityError(
                    f"{label} {item.identity} mutability mismatch: "
                    f"Rust {item.state_mutability}, artifact {found.state_mutability}"
                )
        else:
            if item.indexed != found.indexed:
                raise ParityError(
                    f"{label} {item.identity} indexed fields mismatch: Rust {item.indexed}, artifact {found.indexed}"
                )
            if item.anonymous != found.anonymous:
                raise ParityError(f"{label} {item.identity} anonymous flag mismatch")
        checked += 1
    return checked


def load_artifact(path: Path) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ParityError(f"cannot read Foundry artifact {path}: {error}") from error
    abi = value.get("abi") if isinstance(value, dict) else None
    if not isinstance(abi, list):
        raise ParityError(f"Foundry artifact missing ABI: {path}")
    return abi


def check(rust_source: Path, artifacts_root: Path) -> int:
    try:
        source = strip_comments(rust_source.read_text())
    except OSError as error:
        raise ParityError(f"cannot read Rust ABI source {rust_source}: {error}") from error
    total = 0
    for interface, (label, relative_artifact) in FIRST_PARTY.items():
        expected = source_items(named_block(source, "interface", interface))
        total += assert_subset(label, expected, load_artifact(artifacts_root / relative_artifact))
    return total


def self_test() -> None:
    source = """
        interface IExample {
            struct Pair { uint64 left; address right; }
            function value(address who) external view returns (Pair memory);
            event Changed(address indexed user, uint256 value);
        }
    """
    expected = source_items(named_block(strip_comments(source), "interface", "IExample"))
    artifact = [
        {
            "type": "function",
            "name": "value",
            "inputs": [{"name": "who", "type": "address"}],
            "outputs": [{"name": "", "type": "tuple", "components": [
                {"name": "left", "type": "uint64"}, {"name": "right", "type": "address"}
            ]}],
            "stateMutability": "view",
        },
        {
            "type": "event",
            "name": "Changed",
            "inputs": [
                {"name": "user", "type": "address", "indexed": True},
                {"name": "value", "type": "uint256", "indexed": False},
            ],
            "anonymous": False,
        },
    ]
    if assert_subset("Example", expected, artifact) != 2:
        raise AssertionError("self-test did not check both items")
    changed_output = copy.deepcopy(artifact)
    changed_output[0]["outputs"][0] = {"name": "", "type": "address"}
    try:
        assert_subset("Example", expected, changed_output)
    except ParityError as error:
        if "outputs mismatch" not in str(error):
            raise
    else:
        raise AssertionError("self-test accepted output drift")
    changed_index = copy.deepcopy(artifact)
    changed_index[1]["inputs"][0]["indexed"] = False
    try:
        assert_subset("Example", expected, changed_index)
    except ParityError as error:
        if "indexed fields mismatch" not in str(error):
            raise
    else:
        raise AssertionError("self-test accepted indexed drift")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rust-source", type=Path, default=Path("offchain-rust/src/abi.rs"))
    parser.add_argument("--artifacts", type=Path, default=Path("out"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
            print("offchain ABI parity self-test: passed")
            return 0
        checked = check(args.rust_source, args.artifacts)
    except ParityError as error:
        print(f"offchain ABI parity failed: {error}", file=sys.stderr)
        return 1
    print(f"offchain ABI parity: checked {checked} first-party Rust ABI entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
