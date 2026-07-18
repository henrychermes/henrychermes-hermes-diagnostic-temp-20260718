from fastapi.responses import StreamingResponse
import json
import os
import re
import time
import threading

CODEX_RUN_LOCK = threading.Lock()
import uuid
import shlex
import subprocess
from typing import Any, List, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel


BRIDGE_VERSION = "0.4.0-stdin"

app = FastAPI(title="Codex Bridge", version=BRIDGE_VERSION)


class Message(BaseModel):
    role: str
    content: Optional[Any] = ""


class ChatRequest(BaseModel):
    model: str = "codex-premium"
    messages: List[Message]
    max_tokens: Optional[int] = 2048
    temperature: Optional[float] = None
    stream: Optional[bool] = False


def flatten_content(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text":
                    parts.append(str(item.get("text", "")))
                elif "text" in item:
                    parts.append(str(item.get("text", "")))
            else:
                parts.append(str(item))
        return "\n".join(parts)
    return str(content)


def conversation_prompt(messages: List[Message]) -> str:
    parts = []
    for message in messages:
        content = flatten_content(message.content).strip()
        if content:
            parts.append(f"{message.role.upper()}:\n{content}")
    return "\n\n".join(parts).strip()


def clean_codex_output(text: str) -> str:
    if not text:
        return ""

    ansi_escape = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
    text = ansi_escape.sub("", text)

    lines = [line.rstrip() for line in text.splitlines()]
    cleaned = []

    skip_prefixes = (
        "OpenAI Codex",
        "--------",
        "workdir:",
        "model:",
        "provider:",
        "approval:",
        "sandbox:",
        "reasoning effort:",
        "reasoning summaries:",
        "session id:",
        "tokens used",
    )

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.lower() in ("user", "codex"):
            continue
        if any(stripped.startswith(prefix) for prefix in skip_prefixes):
            continue
        cleaned.append(stripped)

    return "\n".join(cleaned).strip()


def premium_quota_message(stderr: str) -> str:
    matches = re.findall(r"You've hit your usage limit\.[^\r\n]*", str(stderr or ""), flags=re.IGNORECASE)
    return matches[-1].strip() if matches else ""


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "codex-bridge",
        "version": BRIDGE_VERSION
    }


@app.get("/v1/models")
def models():
    return {
        "object": "list",
        "data": [
            {
                "id": "codex-premium",
                "object": "model",
                "description": "Local bridge to Codex CLI"
            }
        ]
    }


@app.post("/v1/chat/completions")
def chat_completions(req: ChatRequest):
    prompt = conversation_prompt(req.messages)

    if not prompt:
        raise HTTPException(status_code=400, detail="No prompt found in messages.")

    codex_cmd = r"C:\Users\henry.000\AppData\Roaming\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe"
    codex_args = shlex.split("exec --sandbox danger-full-access --skip-git-repo-check --")
    timeout_sec = int(os.environ.get("CODEX_TIMEOUT_SECONDS", "600"))

    workdir = os.environ.get("CODEX_BRIDGE_WORKDIR")
    if not workdir:
        workdir = r"C:\Users\henry.000\hermes-oracle-app"

    # Select the original workspace saved for a historical Hermes session.
    marker_prefix = "[[HERMES_SESSION_WORKDIR:"
    marker_start = prompt.rfind(marker_prefix)
    if marker_start >= 0:
        marker_end = prompt.find("]]", marker_start)
        if marker_end >= 0:
            candidate = prompt[
                marker_start + len(marker_prefix):marker_end
            ].strip()
            if os.path.isdir(candidate):
                workdir = candidate

    os.makedirs(workdir, exist_ok=True)

    debug_dir = os.path.join(os.path.expanduser("~"), "workspace", "codex-bridge", "debug")
    os.makedirs(debug_dir, exist_ok=True)

    # A prompt can exceed Windows' command-line limit. Codex accepts `-` to read it from stdin.
    cmd = [codex_cmd] + codex_args + ["-"]

    with open(os.path.join(debug_dir, "last_prompt.txt"), "w", encoding="utf-8") as f:
        f.write(prompt)

    with open(os.path.join(debug_dir, "last_cmd.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(cmd))

    started = time.time()

    # Reject overlapping retries instead of spawning concurrent Codex jobs.
    if not CODEX_RUN_LOCK.acquire(blocking=False):
        raise HTTPException(
            status_code=429,
            detail="Codex bridge is busy with another Hermes request.",
        )

    try:
        try:
            proc = subprocess.run(
                cmd,
                cwd=workdir,
                input=prompt,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout_sec,
            )
        except subprocess.TimeoutExpired:
            raise HTTPException(
                status_code=504,
                detail=f"Codex timed out after {timeout_sec} seconds.",
            )
        except FileNotFoundError:
            raise HTTPException(
                status_code=500,
                detail=f"Could not find Codex command: {codex_cmd}",
            )
    finally:
        CODEX_RUN_LOCK.release()

    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()

    with open(os.path.join(debug_dir, "last_stdout.txt"), "w", encoding="utf-8") as f:
        f.write(stdout)

    with open(os.path.join(debug_dir, "last_stderr.txt"), "w", encoding="utf-8") as f:
        f.write(stderr)

    if proc.returncode != 0:
        quota_message = premium_quota_message(stderr)
        if quota_message:
            raise HTTPException(
                status_code=429,
                detail={"error": "premium_quota", "message": quota_message},
            )
        raise HTTPException(
            status_code=500,
            detail={
                "error": "Codex command failed",
                "returncode": proc.returncode,
                "stdout": stdout[-3000:],
                "stderr": stderr[-3000:],
                "debug_dir": debug_dir
            },
        )

    content = clean_codex_output(stdout) or clean_codex_output(stderr) or stdout or stderr
    elapsed = time.time() - started

    if req.stream:
        completion_id = f"chatcmpl-codexbridge-{uuid.uuid4().hex[:12]}"
        created = int(time.time())

        def event_stream():
            chunks = [
                {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": "codex-premium",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"role": "assistant"},
                            "finish_reason": None,
                        }
                    ],
                },
                {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": "codex-premium",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": content},
                            "finish_reason": None,
                        }
                    ],
                },
                {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": "codex-premium",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {},
                            "finish_reason": "stop",
                        }
                    ],
                },
            ]

            for chunk in chunks:
                yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"

            yield "data: [DONE]\n\n"

        return StreamingResponse(
            event_stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    return {
        "id": f"chatcmpl-codexbridge-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": "codex-premium",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": content
                },
                "finish_reason": "stop"
            }
        ],
        "usage": {
            "elapsed_seconds": round(elapsed, 2)
        },
        "bridge_debug": {
            "version": BRIDGE_VERSION,
            "debug_dir": debug_dir
        }
    }





