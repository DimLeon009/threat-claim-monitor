# Local analysis contract

## Scope

Milestone 3 uses host-native Ollama only to summarize bounded normalized evidence in French. The model has no tools, retrieval, browser, credentials, workflow control, or authority over organization matching, confidence, verification, notifications, or operational actions.

The primary profile is `qwen3:8b-q4_K_M`; `qwen3:4b-q4_K_M` is the explicit lower-memory fallback. Profiles, runtime limits, prompts, and the output schema live under `ai/` and are reviewed like application code.

## Pinned primary model

| Field | Value |
|---|---|
| Ollama tag | `qwen3:8b-q4_K_M` |
| Expected digest | `500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41` |
| Validated Ollama version | `0.32.14` |
| Temperature | `0` |
| Thinking | Disabled |
| Streaming | Disabled |
| Context limit | 4096 tokens |
| Output limit | 1024 tokens |

The 1,024-token output limit was confirmed during the Apple Silicon runtime
validation. Six identical trials with a 512-token limit returned truncated
invalid JSON. Three trials with the 1,024-token limit completed with
`done_reason = stop`, produced 542 output tokens, and passed schema and semantic
validation.

The connectivity check rejects an installed model whose digest differs from the profile. The 4B fallback is not silently selected: it has its own profile and must be installed and chosen explicitly.

## Input boundary

Only allow-listed claim fields and at most ten observations enter the prompt. Each description is limited to 1,000 characters and the complete serialized evidence to 12,000 characters. Evidence identifiers are reassigned deterministically as `evidence-1` through `evidence-10`.

Source descriptions are attacker-influenced data. The user prompt places their JSON inside a fixed `UNTRUSTED_EVIDENCE` boundary and warns that delimiter-like strings inside values remain untrusted content. The system prompt rejects embedded instructions, URLs, pseudo-roles, tool requests, invented missing values, and control-plane decisions.

## Output boundary

The JSON Schema is supplied both in the prompt and as Ollama’s `format` value. It permits only:

- a French summary of at most 600 characters;
- up to five facts, each linked to known evidence identifiers;
- up to five bounded uncertainties;
- the constant French uncertainty disclaimer.

`additionalProperties` is false. Local semantic validation also rejects unknown evidence identifiers, URLs, control-field names, and claims that an incident or compromise is confirmed. Invalid output is discarded and replaced by the deterministic fallback; it never blocks claim processing.

Ollama documents JSON Schema objects in `format`, temperature zero for more deterministic output, `think = false`, and `keep_alive = 0` for immediate unloading. See the official [structured-output](https://docs.ollama.com/capabilities/structured-outputs), [chat API](https://docs.ollama.com/api/chat), and [thinking](https://docs.ollama.com/capabilities/thinking) documentation.

## Workflow and persistence

`WF-40 Local analysis` is stored as the sanitized export `n8n/workflows/wf-40-local-analysis.json`. It can run manually or as a sub-workflow. Its PostgreSQL nodes:

1. load at most ten eligible jobs with `get_pending_claim_analysis_jobs('claim-analysis-v1', 10)`;
2. send one bounded request per job to host-native Ollama;
3. validate the response locally and replace any unavailable, timed-out, or invalid result with the fixed deterministic fallback;
4. persist one provenance envelope through `persist_claim_analysis_result`.

Migration `010_local_analysis_provenance` stores the claim evidence version, pinned model name and digest, prompt version, exact bounded input payload and SHA-256 hash, validated output, validation status, sanitized failure, and bounded inference metrics. The database independently verifies the input hash, output shape, evidence references, claim version, and allow-listed fallback reason. Replaying the same claim, prompt, and input is idempotent.

The workflow contains no credential identifier. After import into n8n, assign `PostgreSQL - Threat Claim Monitor` to both PostgreSQL nodes. The HTTP node uses the non-secret local endpoint `http://host.docker.internal:11434/api/chat` directly. This preserves n8n's environment-variable access restriction instead of weakening it for one workflow. Publish the workflow only after the credential is assigned.

## Validation

Offline repository validation never requires Ollama:

```sh
python3 scripts/test_ai_contract.py
python3 scripts/test_local_analysis_workflow_contract.py
```

The test checks both model profiles, prompt safety rules, the strict schema, truncation, malicious synthetic evidence, invalid control fields, unsupported evidence references, missing values, and deterministic fallback stability.

Check the installed host model and its digest:

```sh
python3 scripts/check_ollama.py
```

Run the optional real-model injection regression and unload the model afterward:

```sh
python3 scripts/check_ollama.py --smoke-inference --unload
```

The runtime test is intentionally excluded from CI because it requires a multi-gigabyte local model and platform-specific acceleration.

With PostgreSQL running, validate transactional job selection, successful persistence, idempotency, falsified-provenance rejection, and sanitized fallback persistence:

```sh
docker compose exec -T postgres psql -U tcm_admin -d threat_claim_monitor -f /dev/stdin < scripts/test_local_analysis_persistence.sql
```
