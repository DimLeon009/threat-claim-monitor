# Exact organization matching

## Scope

`find_exact_organization_matches` evaluates normalized victim evidence against enabled organizations and explicitly approved aliases. It returns candidates but does not create claims or notifications; those transactional steps belong to the next M2 increment.

The function implements three automatic-match methods:

| Method | Score | Requirement |
|---|---:|---|
| `domain_exact` | 100 | Candidate hostname is the approved registered domain or a true subdomain |
| `name_exact` | 95 | Normalized victim name equals the normalized official organization name |
| `alias_exact` | Configured | Normalized victim name equals an alias explicitly configured with mode `exact` |

When several methods match the same organization, only its highest-confidence candidate is returned.

## Collision behavior

An exact string can still be ambiguous when configuration maps it to more than one enabled organization. If exactly one organization matches, the function returns `review_status = auto_accepted`. If multiple organizations match, every candidate is returned as `pending` with:

- `collision = true`;
- `candidate_organization_count`;
- `auto_alert_eligible = false`.

This fail-closed rule takes precedence over the nominal confidence score. A score of 100 never bypasses a configuration collision.

## Evidence

Each result includes JSON evidence with rule version `exact-v1` and only the comparison material needed to explain the decision. Domain evidence records the normalized candidate and approved boundary. Name and alias evidence record the normalized values used by the rule.

No fuzzy or token similarity exists in this function. Later review-candidate logic must remain separate and can never set `auto_accepted`.

## Validation

The synthetic corpus includes positive name, domain, and alias matches; lookalike domains; punctuation differences; and negative collision-oriented values.

Run:

```sh
python3 scripts/test_matching_contract.py
```

Runtime SQL validation should also insert a temporary conflicting alias inside a transaction and confirm that all returned candidates are `pending`, then roll the transaction back.
