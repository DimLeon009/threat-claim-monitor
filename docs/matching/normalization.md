# Deterministic matching normalization

## Purpose

Milestone 2 normalizes untrusted victim, domain, and threat-actor values before correlation or watchlist evaluation. Normalization produces comparison keys only; the original observation remains unchanged as evidence.

No fuzzy score can produce an automatic match. The initial M2 increment implements only deterministic transformations and approved-domain boundary checks.

## Text normalization

`normalize_match_text` applies this ordered contract:

1. remove accents with PostgreSQL `unaccent`;
2. convert to lowercase;
3. replace punctuation and separators with one ASCII space;
4. collapse whitespace and trim;
5. return `NULL` for an empty result.

For example, `Digit Ré Group` and `DIGIT-RE__Group` both normalize to `digit re group`. `Cap France` remains `cap france`; normalization never joins tokens to manufacture a match with `Capifrance`.

`normalize_threat_actor` first uses the same transformation, then resolves enabled canonical names and administrator-approved exact aliases through the table-driven contract documented in `threat-actor-aliases.md`. Unknown actors keep their normalized input, and ambiguous configuration fails closed.

## Domain normalization

`normalize_domain` accepts a hostname or an absolute URL and returns a lowercase ASCII hostname. It removes a scheme, path, query, fragment, numeric port, leading wildcard, and terminal dot.

The function fails closed with `NULL` for:

- credentials or user-info syntax;
- IP addresses;
- single-label values;
- invalid label characters;
- empty, oversized, or malformed labels.

Internationalized domains must arrive in their ASCII `xn--` representation. The workflow does not guess a Unicode-to-punycode conversion.

## Approved registered-domain boundary

The project does not guess a public suffix from arbitrary source text. `domain_matches_registered` compares the normalized candidate against a registered domain explicitly approved in the organization watchlist. A candidate matches only when it is identical to that domain or is a true subdomain separated by a dot.

Therefore:

- `portal.capifrance.fr` matches approved domain `capifrance.fr`;
- `notcapifrance.fr` does not match;
- `capifrance.fr.evil.invalid` does not match.

`extract_approved_registered_domain` evaluates an array of approved domains and returns the longest valid boundary match. This avoids unsafe last-two-label heuristics for multi-label public suffixes.

## Test corpus

The repository-safe corpus is stored in `fixtures/matching/normalization-corpus.json`. It includes accented names, punctuation variants, actor labels, URLs, subdomains, lookalike suffixes, invalid hostnames, and collision-oriented negative cases.

Run the contract validation with:

```sh
python3 scripts/test_matching_contract.py
```

The SQL migration is `004_matching_normalization.sql`. Exact organization matching and claim correlation build on these functions in the next M2 increment.
