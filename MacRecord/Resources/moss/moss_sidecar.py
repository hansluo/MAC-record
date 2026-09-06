#!/usr/bin/env python3
"""Versioned stdio bridge for MOSS-Transcribe-Diarize MLX inference."""

import contextlib
import json
import os
import sys
import time
import traceback

PROTOCOL_VERSION = 1
DEFAULT_MODEL = "vanch007/mlx-MOSS-Transcribe-Diarize-8bit"


def emit(event_type, request_id=None, **payload):
    message = {"protocolVersion": PROTOCOL_VERSION, "type": event_type}
    if request_id is not None:
        message["requestId"] = request_id
    message.update(payload)
    sys.stdout.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def health(request):
    request_id = request.get("requestId")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            import mlx  # noqa: F401
            from moss_transcribe_diarize.mlx import load_model  # noqa: F401
        emit(
            "health",
            request_id,
            ready=True,
            runtime="mlx",
            modelId=DEFAULT_MODEL,
            capabilities={
                "realtime": False,
                "fileTranscription": True,
                "speakerLabels": True,
                "timestamps": True,
                "hotwords": True,
            },
        )
    except Exception as exc:
        emit("error", request_id, code="runtime_unavailable", message=str(exc))


def transcribe(request):
    request_id = request.get("requestId")
    audio_path = request.get("audioPath", "")
    model_id = request.get("modelId") or DEFAULT_MODEL
    max_tokens = int(request.get("maxTokens", 8192))
    hotwords = [str(item).strip() for item in request.get("hotwords", []) if str(item).strip()]

    if not audio_path or not os.path.isfile(audio_path):
        emit("error", request_id, code="input_not_found", message="Audio file does not exist")
        return

    prompt = (
        "请将音频转写为文本，每一段需以起始时间戳和说话人编号"
        "（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，"
        "并在段末标注结束时间戳。"
    )
    if hotwords:
        prompt += "热词提示：" + ", ".join(hotwords)

    try:
        started = time.monotonic()
        emit("progress", request_id, stage="loadingModel", progress=0.05)
        with contextlib.redirect_stdout(sys.stderr):
            from moss_transcribe_diarize.mlx import load_model
            model = load_model(model_id, strict=True)
        emit("progress", request_id, stage="transcribing", progress=0.20)
        with contextlib.redirect_stdout(sys.stderr):
            result = model.generate(
                audio_path,
                max_tokens=max_tokens,
                temperature=0.0,
                prompt=prompt,
                stream=False,
            )

        segments = []
        for segment in result.segments or []:
            segments.append({
                "start": float(segment.get("start", 0.0)),
                "end": float(segment.get("end", 0.0)),
                "speaker": segment.get("speaker_id"),
                "text": str(segment.get("text", "")).strip(),
            })

        emit(
            "result",
            request_id,
            progress=1.0,
            text=result.text,
            language=result.language,
            segments=segments,
            modelId=model_id,
            elapsed=time.monotonic() - started,
            promptTokens=result.prompt_tokens,
            generationTokens=result.generation_tokens,
            generationTPS=result.generation_tps,
        )
    except KeyboardInterrupt:
        emit("cancelled", request_id)
    except Exception as exc:
        emit(
            "error",
            request_id,
            code="transcription_failed",
            message=str(exc),
            diagnostics=traceback.format_exc(limit=8),
        )


def main():
    raw = sys.stdin.readline()
    if not raw:
        return 2
    try:
        request = json.loads(raw)
    except json.JSONDecodeError as exc:
        emit("error", code="invalid_json", message=str(exc))
        return 2

    command = request.get("command")
    if command == "health":
        health(request)
    elif command == "transcribe":
        transcribe(request)
    else:
        emit("error", request.get("requestId"), code="unknown_command", message=str(command))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
