"""Validate the deterministic M2 normalization corpus and SQL contract."""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CORPUS_FILE = REPOSITORY_ROOT / "fixtures/matching/normalization-corpus.json"
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
DOMAIN_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")
ORGANIZATIONS = (
    {
        "name": "Capifrance",
        "domains": ("capifrance.fr",),
        "aliases": (("Capifrance", 95),),
    },
    {
        "name": "Optimhome",
        "domains": ("optimhome.com",),
        "aliases": (("Optimhome", 95),),
    },
    {
        "name": "Digit RE Group",
        "domains": ("digitregroup.com",),
        "aliases": (("Digit RE Group", 95), ("DigitRE Group", 90)),
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


def main() -> int:
    errors: list[str] = []
    corpus = json.loads(CORPUS_FILE.read_text(encoding="utf-8"))

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

    if errors:
        print("Matching contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    case_count = sum(len(corpus[key]) for key in corpus)
    print(f"Matching contract validation passed ({case_count} deterministic cases).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
