"""Deterministic preparation and validation for the local-analysis contract."""

from __future__ import annotations

import copy
import json
import re
from typing import Any


DISCLAIMER = "Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée."
OUTPUT_KEYS = {"language", "summary_fr", "observed_facts", "uncertainties", "disclaimer"}
FACT_KEYS = {"statement_fr", "evidence_ids"}
EVIDENCE_ID = re.compile(r"^evidence-[0-9]{1,2}$")
FORBIDDEN_OUTPUT = re.compile(
    r"https?://|confidence_score|verification_status|auto_alert_eligible|"
    r"compromission\s+(?:est\s+)?confirmée|incident\s+(?:est\s+)?confirmé",
    re.IGNORECASE,
)


def prepare_evidence(payload: dict[str, Any], limits: dict[str, int]) -> dict[str, Any]:
    """Allow-list and deterministically truncate evidence before prompting."""
    claim = payload.get("claim") if isinstance(payload.get("claim"), dict) else {}
    prepared: dict[str, Any] = {
        "claim": {
            key: claim.get(key)
            for key in (
                "victim_name",
                "threat_actor",
                "claimed_at",
                "first_seen_at",
                "last_seen_at",
            )
        },
        "observations": [],
    }

    observations = payload.get("observations")
    if not isinstance(observations, list):
        observations = []
    for index, item in enumerate(observations[: limits["max_observations"]], start=1):
        if not isinstance(item, dict):
            continue
        description = item.get("description")
        if not isinstance(description, str):
            description = None
        elif len(description) > limits["max_description_characters"]:
            description = description[: limits["max_description_characters"] - 1] + "…"
        prepared["observations"].append(
            {
                "evidence_id": f"evidence-{index}",
                "source_name": item.get("source_name") if isinstance(item.get("source_name"), str) else None,
                "published_at": item.get("published_at") if isinstance(item.get("published_at"), str) else None,
                "discovered_at": item.get("discovered_at") if isinstance(item.get("discovered_at"), str) else None,
                "description": description,
            }
        )

    while len(json.dumps(prepared, ensure_ascii=False)) > limits["max_total_characters"]:
        descriptions = [
            item for item in prepared["observations"] if isinstance(item.get("description"), str)
        ]
        if not descriptions:
            prepared["observations"] = prepared["observations"][:-1]
            if not prepared["observations"]:
                break
            continue
        longest = max(descriptions, key=lambda item: len(item["description"]))
        if len(longest["description"]) <= 101:
            longest["description"] = None
        else:
            longest["description"] = longest["description"][:-100]
    return prepared


def validate_analysis_output(payload: Any, evidence_ids: set[str]) -> list[str]:
    """Validate the strict output shape plus evidence-reference semantics."""
    errors: list[str] = []
    if not isinstance(payload, dict):
        return ["output must be a JSON object"]
    if set(payload) != OUTPUT_KEYS:
        errors.append("output keys do not match the strict contract")
    if payload.get("language") != "fr":
        errors.append("language must be fr")
    summary = payload.get("summary_fr")
    if not isinstance(summary, str) or not 1 <= len(summary) <= 600:
        errors.append("summary_fr must contain 1 to 600 characters")
    if payload.get("disclaimer") != DISCLAIMER:
        errors.append("disclaimer does not match the required constant")

    facts = payload.get("observed_facts")
    if not isinstance(facts, list) or len(facts) > 5:
        errors.append("observed_facts must be an array with at most five items")
    else:
        for index, fact in enumerate(facts):
            if not isinstance(fact, dict) or set(fact) != FACT_KEYS:
                errors.append(f"fact {index + 1} has invalid keys")
                continue
            statement = fact.get("statement_fr")
            if not isinstance(statement, str) or not 1 <= len(statement) <= 240:
                errors.append(f"fact {index + 1} has an invalid statement")
            references = fact.get("evidence_ids")
            if (
                not isinstance(references, list)
                or not 1 <= len(references) <= 10
                or len(references) != len(set(references))
                or any(not isinstance(item, str) or not EVIDENCE_ID.fullmatch(item) for item in references)
                or any(item not in evidence_ids for item in references)
            ):
                errors.append(f"fact {index + 1} has invalid evidence references")

    uncertainties = payload.get("uncertainties")
    if (
        not isinstance(uncertainties, list)
        or len(uncertainties) > 5
        or len(uncertainties) != len(set(uncertainties))
        or any(not isinstance(item, str) or not 1 <= len(item) <= 200 for item in uncertainties)
    ):
        errors.append("uncertainties must contain up to five unique bounded strings")

    text_values: list[str] = []
    if isinstance(summary, str):
        text_values.append(summary)
    if isinstance(facts, list):
        text_values.extend(
            fact.get("statement_fr", "") for fact in facts if isinstance(fact, dict)
        )
    if isinstance(uncertainties, list):
        text_values.extend(item for item in uncertainties if isinstance(item, str))
    if any(FORBIDDEN_OUTPUT.search(value) for value in text_values):
        errors.append("output contains a URL, control-plane term, or confirmation claim")
    return errors


def deterministic_fallback(prepared_evidence: dict[str, Any]) -> dict[str, Any]:
    """Return a safe summary when local inference is unavailable or invalid."""
    return {
        "language": "fr",
        "summary_fr": (
            "Une ou plusieurs sources publiques relaient une déclaration concernant "
            "l’organisation surveillée. Les preuves disponibles ne confirment pas une compromission."
        ),
        "observed_facts": [],
        "uncertainties": ["Analyse locale indisponible ou invalide ; consulter les preuves sources."],
        "disclaimer": DISCLAIMER,
    }


def clone_json(value: Any) -> Any:
    """Return a JSON-compatible deep copy for mutation tests."""
    return copy.deepcopy(value)
