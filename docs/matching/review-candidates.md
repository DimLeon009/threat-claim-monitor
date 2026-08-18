# Token and fuzzy review candidates

## Purpose

Migration `009_review_match_candidates` identifies plausible organization matches that are not strong enough for automatic handling. These records exist only to support later analyst review; they never create an alert-eligible decision.

## Token candidates

A token rule must be explicitly configured as an `organization_aliases` row with `matching_mode = token`. The approved alias must contain at least two distinct normalized tokens, and every approved token must occur as a complete token in the candidate victim name.

Token confidence is configured between 70 and 84. Extra candidate tokens are allowed, but partial words, missing tokens, and single-token aliases do not match.

## Fuzzy candidates

Fuzzy comparison uses PostgreSQL `pg_trgm` similarity only against enabled organizations' official names. Both normalized values must contain at least five characters, must not be exact, and must reach similarity `0.60`.

The stored fuzzy score is the integer similarity percentage capped at 69. Fuzzy aliases and automatic alias discovery are deliberately unsupported.

## Safety invariants

Every result from `find_review_organization_candidates` has:

- `review_status = pending`;
- `auto_alert_eligible = false`;
- rule version `review-v1`;
- normalized comparison evidence and the applicable token or similarity inputs.

Organizations already returned by exact matching are excluded. Persistence can improve an unreviewed token or fuzzy candidate with stronger review evidence, but it cannot overwrite `auto_accepted`, `accepted`, or `rejected` decisions. Replaying an observation preserves human review state.

## Validation

`fixtures/matching/review-candidate-corpus.json` records the scoring and safety contract. `scripts/test_review_candidate_contract.sql` checks positive and negative token rules, fuzzy threshold behavior, durable pending matches, absence of automatic acceptance, and preservation of a human decision. All runtime test data is rolled back.
