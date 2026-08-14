## Summary

Explain the outcome of this pull request in one or two paragraphs.

## Motivation

What problem does this solve? Why is the change needed now?

Closes #

## Changes

Describe the main implementation changes.

## Architecture and security impact

- Architecture or trust boundary changed: Yes / No
- ADR required or updated: Yes / No / Not applicable
- New secret or permission required: Yes / No
- Data model or retention changed: Yes / No
- External source or notification behavior changed: Yes / No

Explain every “Yes”.

## Validation

List exact tests and results.

```text
commands and sanitized results
```

## Failure and rollback

Describe expected failure behavior and how to safely revert or disable the change.

## Checklist

- [ ] Scope matches one issue and one observable outcome.
- [ ] Repository validation passes.
- [ ] Relevant positive, negative, retry, and failure tests pass.
- [ ] n8n workflow exports are sanitized and reviewable.
- [ ] No secret, personal data, leaked material, or unsafe payload is included.
- [ ] Source and model content remain untrusted.
- [ ] Match confidence and verification remain deterministic.
- [ ] Documentation and roadmap status are accurate.
- [ ] Logs and persisted errors are sanitized.
- [ ] No unnecessary infrastructure dependency was introduced.

## Evidence

Add sanitized screenshots, workflow diagrams, or logs only when they materially help review.
