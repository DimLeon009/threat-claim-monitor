# SQL parameterization review

## Decision

The source-derived SQL boundary was reviewed on 2026-08-28. All committed n8n
PostgreSQL nodes are either fixed queries with no runtime value interpolation or
use positional PostgreSQL placeholders with n8n Query Parameters. The database
migrations contain no dynamic SQL execution.

This review covers every `n8n-nodes-base.postgres` node exported under
`n8n/workflows/` and migrations 001 through 026. The synthetic SQL files under
`scripts/` are local, fixed test harnesses and do not process external runtime
input.

## Reviewed inventory

| Workflow | Fixed queries | Parameterized queries |
|---|---|---|
| WF-00 Orchestrator | Provider selection and three source gates | None |
| WF-10 ransomware.live | None | Observation ingestion, correlation, correlation failure, collection failure |
| WF-11 RansomLook | None | Observation ingestion, correlation, correlation failure, collection failure |
| WF-12 FrenchBreaches | None | Observation ingestion, correlation, correlation failure, collection failure |
| WF-40 Local analysis | Pending-job selection | Analysis-result persistence |
| WF-41 Microsoft Foundry analysis | Configured-job selection | Analysis-result persistence |
| WF-50 Notification producer | Notification enqueue | None |
| WF-60 Generic webhook | Job claim | Delivery-result persistence |
| WF-61 SMTP email | Job claim | Delivery-result persistence |
| WF-62 Teams Workflows | Job claim | Delivery-result persistence |
| WF-70 Retention | Preview and bounded apply | None |
| WF-71 Operational dashboards | Summary, source, and channel views | None |

The resulting inventory contains 16 fixed and 17 parameterized PostgreSQL
nodes. Source records, collection-run identifiers, sanitized failure codes,
model results, and delivery results enter SQL only through `$1` placeholders.
Expressions are confined to the Query Parameters field and never inserted into
the SQL text.

PostgreSQL `format()` is used in migrations 013 and 017 only to construct
deduplication-key data inside fixed SQL functions. It does not construct or
execute SQL. No migration uses PL/pgSQL `EXECUTE`, `quote_ident()`, or
`quote_literal()`.

## Automated gate

`scripts/test_sql_parameterization_contract.py` enforces the reviewed inventory.
It rejects:

- a new or renamed PostgreSQL node that has not been explicitly reviewed;
- n8n expressions in SQL query text;
- positional placeholders without Query Parameters;
- Query Parameters without contiguous placeholders starting at `$1`;
- parameterized nodes without single-query batching;
- dynamic SQL construction in migrations.

The contract runs on Windows, macOS/Linux, and in CI through the repository
validation scripts. n8n also reports expressions in SQL fields and Query
Parameters through its native security audit; constant queries can legitimately
have no Query Parameters. See the official [n8n security audit
documentation](https://docs.n8n.io/hosting/securing/security-audit/).

## Change rule and residual risk

Any PostgreSQL workflow-node addition or rename must update the explicit test
inventory and receive a security review. Runtime SQL identifiers cannot use
ordinary value parameters. If a future feature needs a dynamic table, column,
schema, or sort direction, it must map the input through a fixed allow-list and
receive a dedicated review before merge.

Database functions remain part of the trusted code base. Existing controls do
not replace least-privilege credentials, schema validation, transaction tests,
or review of every new migration.
