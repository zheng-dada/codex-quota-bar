#!/usr/bin/python3
"""Local stdio fixture: no network, credentials, or model calls."""
import json
import os
import sys
import time

mode = os.environ.get("CODEX_QUOTA_TEST_MODE", "normal")
log = os.environ.get("CODEX_QUOTA_TEST_LOG")
for line in sys.stdin:
    request = json.loads(line)
    if log:
        with open(log, "a", encoding="utf-8") as stream:
            stream.write(request["method"] + "\n")
    if request["method"] == "initialized":
        continue
    if mode == "exit":
        sys.exit(0)
    if mode == "timeout":
        time.sleep(30)
        continue
    if request["method"] == "initialize":
        response = {"id": request["id"], "result": {"userAgent": "test"}}
    elif mode == "auth":
        response = {"id": request["id"], "error": {"code": -32001, "message": "401 authentication required"}}
    else:
        bucket = {
            "limitId": "codex",
            "primary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1999999999},
            "secondary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 2000000999},
            "planType": "plus",
        }
        result = {"rateLimits": bucket, "rateLimitsByLimitId": {"codex": bucket}}
        if mode == "missing":
            result = {"rateLimits": {"limitId": "other"}}
        elif mode == "invalid":
            result = {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": "invalid"}}}
        response = {"id": request["id"], "result": result}
    # Exercise notifications, multiple frames per read, and fragmented frames.
    os.write(1, b'{"method":"test/notification","params":{}}\n')
    payload = (json.dumps(response) + "\n").encode()
    midpoint = len(payload) // 2
    os.write(1, payload[:midpoint])
    time.sleep(0.005)
    os.write(1, payload[midpoint:])
