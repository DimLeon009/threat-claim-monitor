"""Check host-native Ollama and optionally run the M3 structured-output smoke test."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

from ai_contract import prepare_evidence, validate_analysis_output


ROOT = Path(__file__).resolve().parent.parent


def request_json(url: str, payload: dict | None, timeout: int) -> dict:
    body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"} if body else {},
        method="POST" if body else "GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:11434")
    parser.add_argument("--profile", type=Path, default=ROOT / "ai/models/qwen3-8b-q4_K_M.json")
    parser.add_argument("--smoke-inference", action="store_true")
    parser.add_argument("--unload", action="store_true")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    profile = json.loads(args.profile.read_text(encoding="utf-8"))
    schema = json.loads((ROOT / "ai/schemas/claim-analysis-v1.schema.json").read_text(encoding="utf-8"))
    try:
        version = request_json(f"{args.base_url}/api/version", None, 10)["version"]
        tags = request_json(f"{args.base_url}/api/tags", None, 10).get("models", [])
    except (OSError, urllib.error.URLError, ValueError, KeyError) as error:
        print(f"Ollama connectivity check failed: {type(error).__name__}", file=sys.stderr)
        return 1

    installed = next((item for item in tags if item.get("name") == profile["model"]), None)
    if installed is None:
        print(f"Required Ollama model is not installed: {profile['model']}", file=sys.stderr)
        return 1
    expected_digest = profile.get("expected_digest")
    expected_prefix = profile.get("expected_digest_prefix")
    digest = installed.get("digest", "")
    if expected_digest and digest != expected_digest:
        print("Installed model digest does not match the pinned profile", file=sys.stderr)
        return 1
    if expected_prefix and not digest.startswith(expected_prefix):
        print("Installed model digest does not match the fallback profile", file=sys.stderr)
        return 1

    result = {"status": "ok", "ollama_version": version, "model": profile["model"], "digest": digest}
    if args.smoke_inference:
        fixture = json.loads(
            (ROOT / "fixtures/ai/prompt-injection.synthetic.json").read_text(encoding="utf-8")
        )
        prepared = prepare_evidence(fixture, profile["input_limits"])
        system_prompt = (ROOT / "ai/prompts/claim-analysis-v1.system.txt").read_text(encoding="utf-8")
        user_template = (ROOT / "ai/prompts/claim-analysis-v1.user.txt").read_text(encoding="utf-8")
        user_prompt = user_template.replace(
            "{{EVIDENCE_JSON}}", json.dumps(prepared, ensure_ascii=False, separators=(",", ":"))
        ).replace("{{OUTPUT_SCHEMA_JSON}}", json.dumps(schema, ensure_ascii=False, separators=(",", ":")))
        runtime = profile["runtime"]
        response = request_json(
            f"{args.base_url}/api/chat",
            {
                "model": profile["model"],
                "stream": runtime["stream"],
                "think": runtime["think"],
                "keep_alive": 0 if args.unload else runtime["keep_alive"],
                "format": schema,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                "options": runtime["options"],
            },
            args.timeout,
        )
        content = json.loads(response["message"]["content"])
        evidence_ids = {item["evidence_id"] for item in prepared["observations"]}
        validation_errors = validate_analysis_output(content, evidence_ids)
        if validation_errors:
            print("Ollama structured-output smoke test failed:", file=sys.stderr)
            for error in validation_errors:
                print(f"- {error}", file=sys.stderr)
            return 1
        result.update(
            {
                "smoke_inference": "valid",
                "done_reason": response.get("done_reason"),
                "prompt_tokens": response.get("prompt_eval_count"),
                "output_tokens": response.get("eval_count"),
            }
        )
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
