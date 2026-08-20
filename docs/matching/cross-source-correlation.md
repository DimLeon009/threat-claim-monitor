# Cross-source claim correlation

## Purpose

Milestone 5 allows independent source adapters to attach compatible observations to one claim without treating repetition by aggregators as confirmation of compromise.

Migration `020_cross_source_correlation.sql` makes collection-run correlation source-independent for enabled sources. WF-10 and WF-11 both use the same deterministic observation correlation function and retain separate collection-run failure histories.

## Deterministic transition

The existing correlation contract still requires compatible normalized victim identity, resolved threat actor, and the bounded 45-day window. Adding a linked observation increments the claim evidence version exactly once.

After correlation, PostgreSQL counts distinct `source_id` values linked to the claim:

- one source preserves `claimed`;
- two or more distinct sources change `claimed` to `multi_source_observed`;
- replaying an already linked observation changes neither the evidence version nor the status;
- `officially_confirmed`, `disputed`, and `refuted` are never replaced by the automatic transition.

`multi_source_observed` means only that multiple monitored aggregators published compatible metadata. It is not independent evidence that compromise occurred and must never be described as official confirmation.

## Notification behavior

The first material non-historical claim version can create one `new_claim` job per enabled organization and channel. Later evidence versions cannot create another `new_claim` for the same claim, organization, and channel.

This lifetime guard is independent of the evidence-version key retained on the original notification. A future explicit `status_change` workflow can notify meaningful transitions without mislabeling them as a new claim; that behavior is outside this increment.

## Failure and replay

Collection-run correlation is transactional. A correlation error changes the run to `partial` with the bounded `correlation_failed` code. Replaying the same run is safe: existing observation links remain unique, evidence versions do not increment twice, and a successful retry clears the sanitized failure state.

Validate the repository contract with:

```sh
python3 scripts/test_cross_source_correlation_contract.py
```

The PostgreSQL runtime test in `scripts/test_cross_source_correlation_contract.sql` uses synthetic records inside a transaction and ends with `ROLLBACK`.

## Windows runtime validation

The Windows PostgreSQL smoke test linked two synthetic observations from distinct configured sources to one claim. The first source created the claim, the second reused it, incremented the evidence version to 2, and changed verification from `claimed` to `multi_source_observed`. Replaying the second collection created no link and did not change the evidence version.

The notification outbox runtime suite then raised the same synthetic claim to a later evidence version with `multi_source_observed` and confirmed that WF-50 produced no additional `new_claim` job. Both tests completed with `ROLLBACK`; no synthetic claim, observation, analysis, match, notification, or channel-state change remained.

The sanitized RansomLook runtime backfill then processed 264 previously collected usable observations across two runs. It created 232 claims and 264 observation links without producing an organization match. Thirty-two resulting claims contained observations from at least two distinct sources; all 32 held `multi_source_observed`, and zero eligible claims remained incorrectly labeled `claimed`.
