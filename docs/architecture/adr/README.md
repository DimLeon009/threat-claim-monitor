# Architecture Decision Records

Architecture Decision Records capture decisions that materially constrain implementation or operations.

## Status values

- **Proposed:** under active discussion;
- **Accepted:** current decision and implementation direction;
- **Superseded:** replaced by a later ADR;
- **Rejected:** considered but not selected;
- **Deprecated:** retained for history but no longer recommended.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [ADR-0001](0001-minimal-v1-architecture.md) | Minimal V1 architecture | Accepted | 2026-08-14 |
| [ADR-0002](0002-hybrid-local-foundry-inference.md) | Hybrid local and Microsoft Foundry inference | Accepted | 2026-08-18 |

## When to write an ADR

Create an ADR when a change:

- adds or removes a persistent service;
- changes a trust boundary or data classification;
- changes the canonical evidence model;
- introduces an operational dependency;
- changes cross-platform support;
- creates a difficult-to-reverse compatibility commitment.

Routine implementation details do not require an ADR.
