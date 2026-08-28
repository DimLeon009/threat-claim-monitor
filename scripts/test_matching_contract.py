"""Validate the deterministic M2 normalization corpus and SQL contract."""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CORPUS_FILE = REPOSITORY_ROOT / "fixtures/matching/normalization-corpus.json"
ACTOR_ALIAS_CORPUS_FILE = REPOSITORY_ROOT / "fixtures/matching/threat-actor-alias-corpus.json"
REVIEW_CORPUS_FILE = REPOSITORY_ROOT / "fixtures/matching/review-candidate-corpus.json"
MIGRATION_FILE = REPOSITORY_ROOT / "db/migrations/004_matching_normalization.sql"
EXACT_MATCH_MIGRATION_FILE = REPOSITORY_ROOT / "db/migrations/005_exact_organization_matching.sql"
CORRELATION_MIGRATION_FILE = REPOSITORY_ROOT / "db/migrations/006_transactional_claim_correlation.sql"
CORRELATION_TEST_FILE = REPOSITORY_ROOT / "scripts/test_correlation_contract.sql"
COLLECTION_CORRELATION_MIGRATION_FILE = (
    REPOSITORY_ROOT / "db/migrations/007_collection_run_correlation.sql"
)
COLLECTION_CORRELATION_TEST_FILE = (
    REPOSITORY_ROOT / "scripts/test_collection_run_correlation_contract.sql"
)
ACTOR_ALIAS_MIGRATION_FILE = REPOSITORY_ROOT / "db/migrations/008_threat_actor_aliases.sql"
ACTOR_ALIAS_TEST_FILE = REPOSITORY_ROOT / "scripts/test_threat_actor_alias_contract.sql"
REVIEW_MIGRATION_FILE = REPOSITORY_ROOT / "db/migrations/009_review_match_candidates.sql"
REVIEW_TEST_FILE = REPOSITORY_ROOT / "scripts/test_review_candidate_contract.sql"
DOMAIN_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")
ORGANIZATIONS = (
    {
        "name": "Aster Habitat [Synthetic]",
        "domains": ("aster-habitat.invalid",),
        "aliases": (("Aster Habitat [Synthetic]", 95),),
    },
    {
        "name": "Boreal Homes [Synthetic]",
        "domains": ("boreal-homes.invalid",),
        "aliases": (("Boreal Homes [Synthetic]", 95),),
    },
    {
        "name": "Cobalt Property Group [Synthetic]",
        "domains": ("cobalt-property.invalid",),
        "aliases": (("Cobalt Property Group [Synthetic]", 95), ("CobaltProperty Group [Synthetic]", 90)),
    },
)


def normalize_match_text(value: str) -> str | None:
    decomposed = unicodedata.normalize("NFKD", value)
    ascii_value = "".join(character for character in decomposed if not unicodedata.combining(character))
    normalized = re.sub(r"[^a-z0-9]+", " ", ascii_value.lower()).strip()
    return normalized or None


def normalize_domain(value: str) -> str | None:
    normalized = value.strip().lower()
    normalized = re.sub(r"^[a-z][a-z0-9+.-]*://", "", normalized)
    if "@" in normalized:
        return None
    normalized = re.sub(r"[/#?].*$", "", normalized)
    normalized = re.sub(r":[0-9]+$", "", normalized)
    normalized = re.sub(r"^\*\.", "", normalized).strip(".")
    labels = normalized.split(".")
    if (
        not normalized
        or len(normalized) > 253
        or "." not in normalized
        or re.fullmatch(r"[0-9.]+", normalized)
        or any(not label or len(label) > 63 or not DOMAIN_LABEL.fullmatch(label) for label in labels)
    ):
        return None
    return normalized


def domain_matches_registered(candidate: str, approved: str) -> bool:
    normalized_candidate = normalize_domain(candidate)
    normalized_approved = normalize_domain(approved)
    if not normalized_candidate or not normalized_approved:
        return False
    return normalized_candidate == normalized_approved or normalized_candidate.endswith(
        f".{normalized_approved}"
    )


def find_exact_match(victim: str, domain: str) -> tuple[str, int] | None:
    candidates: list[tuple[str, int]] = []
    for organization in ORGANIZATIONS:
        if any(domain_matches_registered(domain, approved) for approved in organization["domains"]):
            candidates.append(("domain_exact", 100))
            continue
        if normalize_match_text(victim) == normalize_match_text(organization["name"]):
            candidates.append(("name_exact", 95))
            continue
        alias_scores = [
            score
            for alias, score in organization["aliases"]
            if normalize_match_text(victim) == normalize_match_text(alias)
        ]
        if alias_scores:
            candidates.append(("alias_exact", max(alias_scores)))
    if len(candidates) != 1:
        return None
    return candidates[0]


def resolve_actor_alias(actor_corpus: dict[str, object], input_value: str) -> tuple[str, str]:
    normalized_input = normalize_match_text(input_value)
    candidates: list[tuple[str, str]] = []
    for actor in actor_corpus["actors"]:
        if not actor["enabled"]:
            continue
        canonical = normalize_match_text(actor["canonical_name"])
        if normalized_input == canonical:
            candidates.append((canonical, "canonical_exact"))
        for alias in actor["aliases"]:
            if normalized_input == normalize_match_text(alias):
                candidates.append((canonical, "alias_exact"))

    distinct_actors = {candidate[0] for candidate in candidates}
    if len(distinct_actors) > 1:
        raise ValueError("ambiguous threat actor alias configuration")
    if not candidates:
        return normalized_input, "unmapped"
    return sorted(candidates, key=lambda candidate: candidate[1] != "canonical_exact")[0]


def approved_token_alias_matches(candidate: str, approved_alias: str) -> bool:
    candidate_tokens = set((normalize_match_text(candidate) or "").split())
    approved_tokens = set((normalize_match_text(approved_alias) or "").split())
    return len(approved_tokens) >= 2 and approved_tokens <= candidate_tokens


def main() -> int:
    errors: list[str] = []
    corpus = json.loads(CORPUS_FILE.read_text(encoding="utf-8"))
    actor_corpus = json.loads(ACTOR_ALIAS_CORPUS_FILE.read_text(encoding="utf-8"))
    review_corpus = json.loads(REVIEW_CORPUS_FILE.read_text(encoding="utf-8"))

    for case in corpus["text_cases"] + corpus["actor_cases"]:
        actual = normalize_match_text(case["input"])
        if actual != case["expected"]:
            errors.append(f"text normalization mismatch for {case['input']!r}: {actual!r}")

    for case in corpus["domain_cases"]:
        actual = normalize_domain(case["input"])
        if actual != case["expected"]:
            errors.append(f"domain normalization mismatch for {case['input']!r}: {actual!r}")

    for case in corpus["registered_domain_cases"]:
        actual = domain_matches_registered(case["candidate"], case["approved"])
        if actual is not case["expected"]:
            errors.append(
                f"registered-domain mismatch for {case['candidate']!r} against "
                f"{case['approved']!r}: {actual!r}"
            )

    for case in corpus["exact_match_cases"]:
        actual = find_exact_match(case["victim"], case["domain"])
        expected = None if case["method"] is None else (case["method"], case["score"])
        if actual != expected:
            errors.append(
                f"exact-match mismatch for victim {case['victim']!r} and "
                f"domain {case['domain']!r}: {actual!r}"
            )

    for case in actor_corpus["cases"]:
        actual = resolve_actor_alias(actor_corpus, case["input"])
        expected = (case["expected"], case["method"])
        if actual != expected:
            errors.append(f"actor-alias mismatch for {case['input']!r}: {actual!r}")

    collision_corpus = json.loads(json.dumps(actor_corpus))
    collision = collision_corpus["collision"]
    for actor in collision_corpus["actors"]:
        if actor["canonical_name"] == collision["alias_owner"]:
            actor["aliases"].append(collision["alias"])
    collision_corpus["actors"].append(
        {"canonical_name": collision["canonical_name"], "enabled": True, "aliases": []}
    )
    try:
        resolve_actor_alias(collision_corpus, collision["alias"])
        errors.append("actor alias collision must fail closed")
    except ValueError as error:
        if str(error) != collision["expected_error"]:
            errors.append(f"unexpected actor alias collision error: {error}")

    for case in review_corpus["token_cases"]:
        actual = approved_token_alias_matches(case["candidate"], case["approved_alias"])
        if actual is not case["expected"]:
            errors.append(
                f"token-candidate mismatch for {case['candidate']!r} against "
                f"{case['approved_alias']!r}: {actual!r}"
            )

    invariants = review_corpus["invariants"]
    if (
        invariants["review_status"] != "pending"
        or invariants["auto_alert_eligible"] is not False
        or not 70 <= invariants["token_min_score"] <= invariants["token_max_score"] <= 84
        or invariants["fuzzy_max_score"] >= 70
        or not 0 < invariants["fuzzy_min_similarity"] < 1
    ):
        errors.append("review-candidate corpus contains unsafe scoring invariants")

    migration = MIGRATION_FILE.read_text(encoding="utf-8")
    for function_name in (
        "normalize_match_text",
        "normalize_threat_actor",
        "normalize_domain",
        "domain_matches_registered",
        "extract_approved_registered_domain",
    ):
        if f"FUNCTION {function_name}" not in migration:
            errors.append(f"migration is missing {function_name}")
    if "pg_trgm" in migration or "similarity(" in migration:
        errors.append("the normalization increment must not introduce fuzzy matching")

    exact_match_migration = EXACT_MATCH_MIGRATION_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "FUNCTION find_exact_organization_matches",
        "'domain_exact'::text",
        "'name_exact'::text",
        "'alias_exact'::text",
        "'auto_accepted'",
        "'pending'",
        "'collision'",
    ):
        if required_fragment not in exact_match_migration:
            errors.append(f"exact-match migration is missing {required_fragment}")
    if "fuzzy" in exact_match_migration.lower() or "similarity(" in exact_match_migration:
        errors.append("exact-match evaluation must not contain fuzzy matching")

    correlation_migration = CORRELATION_MIGRATION_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "FUNCTION correlate_observation_exact",
        "pg_advisory_xact_lock",
        "interval '45 days'",
        "ON CONFLICT (observation_id) DO NOTHING",
        "ON CONFLICT ON CONSTRAINT organization_matches_claim_id_organization_id_key",
        "evidence_version = claim.evidence_version + 1",
        "find_exact_organization_matches",
        "ambiguous claim correlation",
    ):
        if required_fragment not in correlation_migration:
            errors.append(f"claim-correlation migration is missing {required_fragment}")

    correlation_test = CORRELATION_TEST_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "\\set ON_ERROR_STOP on",
        "BEGIN;",
        "inside the 45-day window",
        "outside the 45-day window",
        "different threat actors",
        "configuration collision",
        "ROLLBACK;",
    ):
        if required_fragment not in correlation_test:
            errors.append(f"claim-correlation runtime test is missing {required_fragment}")

    collection_migration = COLLECTION_CORRELATION_MIGRATION_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "FUNCTION correlate_collection_run_exact",
        "correlate_observation_exact",
        "'correlation_status', 'succeeded'",
        "FUNCTION record_claim_correlation_failure",
        "'correlation_status', 'failed'",
        "'correlation_failure_code', 'correlation_failed'",
    ):
        if required_fragment not in collection_migration:
            errors.append(f"collection-run correlation migration is missing {required_fragment}")

    collection_test = COLLECTION_CORRELATION_TEST_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "\\set ON_ERROR_STOP on",
        "collection run correlation summary is invalid",
        "collection run replay must not increment evidence_version",
        "correlation failure must be persisted with sanitized metadata",
        "successful retry must recover the collection run state",
        "ROLLBACK;",
    ):
        if required_fragment not in collection_test:
            errors.append(f"collection-run correlation runtime test is missing {required_fragment}")

    actor_alias_migration = ACTOR_ALIAS_MIGRATION_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "CREATE TABLE IF NOT EXISTS threat_actors",
        "CREATE TABLE IF NOT EXISTS threat_actor_aliases",
        "FUNCTION resolve_threat_actor",
        "ambiguous threat actor alias configuration",
        "FUNCTION normalize_threat_actor",
        "'unmapped'::text",
    ):
        if required_fragment not in actor_alias_migration:
            errors.append(f"actor-alias migration is missing {required_fragment}")
    if "fuzzy" in actor_alias_migration.lower() or "similarity(" in actor_alias_migration:
        errors.append("actor-alias resolution must not contain fuzzy matching")

    actor_alias_test = ACTOR_ALIAS_TEST_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "approved actor alias did not resolve",
        "disabled actor aliases must not resolve",
        "actor alias collision must fail closed",
        "canonical actor and approved alias must correlate to one claim",
        "ROLLBACK;",
    ):
        if required_fragment not in actor_alias_test:
            errors.append(f"actor-alias runtime test is missing {required_fragment}")

    review_migration = REVIEW_MIGRATION_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "CREATE EXTENSION IF NOT EXISTS pg_trgm",
        "confidence_score BETWEEN 70 AND 84",
        "FUNCTION approved_token_alias_matches",
        "cardinality(approved.tokens) < 2",
        "FUNCTION find_review_organization_candidates",
        "similarity(",
        "'pending'::text AS review_status",
        "'auto_alert_eligible', false",
        "FUNCTION persist_review_organization_candidates",
        "FUNCTION correlate_observation_exact",
    ):
        if required_fragment not in review_migration:
            errors.append(f"review-candidate migration is missing {required_fragment}")

    review_test = REVIEW_TEST_FILE.read_text(encoding="utf-8")
    for required_fragment in (
        "single-token aliases must not produce review candidates",
        "fuzzy candidate must remain pending",
        "review candidates must never be auto accepted",
        "candidate replay must preserve the human review decision",
        "ROLLBACK;",
    ):
        if required_fragment not in review_test:
            errors.append(f"review-candidate runtime test is missing {required_fragment}")

    if errors:
        print("Matching contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    case_count = (
        sum(len(corpus[key]) for key in corpus)
        + len(actor_corpus["cases"])
        + 1
        + len(review_corpus["token_cases"])
        + len(review_corpus["fuzzy_cases"])
    )
    print(f"Matching contract validation passed ({case_count} deterministic cases).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
