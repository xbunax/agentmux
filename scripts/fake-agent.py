#!/usr/bin/env python3
"""Deterministic native-protocol fixture. No network or LLM calls."""

import json
import sys

kind = "codex" if "app-server" in sys.argv else "pi" if "rpc" in sys.argv else "claude"


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        continue
    if kind == "pi":
        command = value.get("type")
        data = {}
        if command == "get_state":
            data = {"model": {"id": "test-model"}}
        elif command == "get_available_models":
            data = {
                "models": [
                    {"id": "test-model", "name": "Test Model", "provider": "fixture"}
                ]
            }
        elif command == "get_commands":
            data = {"commands": [{"name": "test-command", "description": "fixture"}]}
        send({"id": value.get("id"), "type": "response", "success": True, "data": data})
        if command == "prompt":
            send({"type": "agent_start"})
            send({"type": "message_start", "message": {"role": "assistant"}})
            send(
                {
                    "type": "message_update",
                    "assistantMessageEvent": {
                        "type": "text_delta",
                        "delta": "AGENTMUX_OK",
                    },
                }
            )
            send(
                {
                    "type": "message_end",
                    "message": {
                        "role": "assistant",
                        "content": [{"type": "text", "text": "AGENTMUX_OK"}],
                    },
                }
            )
            send({"type": "agent_settled"})
    elif kind == "claude":
        if value.get("type") == "control_request":
            data = {
                "models": [{"value": "test-model", "displayName": "Test Model"}],
                "commands": [{"name": "test-command", "description": "fixture"}],
            }
            send(
                {
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": value["request_id"],
                        "response": data,
                    },
                }
            )
        elif value.get("type") == "user":
            send(
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "AGENTMUX_OK"}]},
                }
            )
            send({"type": "result", "is_error": False})
    else:
        method = value.get("method")
        if "id" not in value:
            continue
        result = {}
        if method == "thread/start":
            result = {"thread": {"id": "thread-fixture"}, "model": "test-model"}
        elif method == "model/list":
            result = {"data": [{"model": "test-model", "displayName": "Test Model"}]}
        elif method == "turn/start":
            result = {"turn": {"id": "turn-fixture"}}
        send({"id": value["id"], "result": result})
        if method == "turn/start":
            send({"method": "turn/started", "params": {"turn": {"id": "turn-fixture"}}})
            send(
                {
                    "method": "item/agentMessage/delta",
                    "params": {"itemId": "message-fixture", "delta": "AGENTMUX_OK"},
                }
            )
            send(
                {
                    "method": "item/completed",
                    "params": {
                        "item": {
                            "id": "message-fixture",
                            "type": "agentMessage",
                            "text": "AGENTMUX_OK",
                        }
                    },
                }
            )
            send(
                {"method": "turn/completed", "params": {"turn": {"id": "turn-fixture"}}}
            )
