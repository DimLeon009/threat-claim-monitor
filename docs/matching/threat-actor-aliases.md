# Threat-actor aliases

## Purpose

Threat-group names vary across feeds and over time. Migration `008_threat_actor_aliases` adds an explicit, administrator-approved mapping layer so known aliases can share one canonical correlation key without introducing fuzzy inference.

## Resolution rules

`resolve_threat_actor` first applies the ordinary Unicode, punctuation, and whitespace normalization contract. It then evaluates enabled canonical names and enabled aliases:

- an enabled canonical name returns `canonical_exact`;
- an enabled approved alias returns `alias_exact` and the canonical actor key;
- an unknown or disabled name returns `unmapped` and keeps its normalized input;
- names resolving to more than one enabled actor fail with `ambiguous threat actor alias configuration`.

`normalize_threat_actor` exposes the resolved canonical key to claim correlation. There is no token similarity, fuzzy score, external enrichment, or automatic alias discovery.

## Configuration

Canonical actors live in `threat_actors`; approved alternative spellings live in `threat_actor_aliases`. Normalized columns must exactly match `normalize_match_text`, and aliases are unique after normalization. No real-world aliases are seeded by the migration: an administrator must verify and approve each mapping before insertion.

Disabling either an actor or an alias immediately removes it from future resolution. Existing source observations remain unchanged. Correlation reads the original actor label again, so an approved mapping can also resolve older, not-yet-linked observations.

## Validation

The synthetic corpus covers canonical, alias, unknown, disabled, and collision behavior. `scripts/test_threat_actor_alias_contract.sql` additionally proves that a canonical actor label and its approved alias correlate to one claim, then rolls back every test row.
