# Support and reporting

Use this guide to choose the right GitHub channel. The repository has Issues
enabled and Discussions disabled.

## Installation or usage problem

First follow, in order:

1. the [getting-started guide](docs/operations/getting-started.md);
2. the [workflow deployment guide](docs/operations/workflow-deployment.md);
3. the [health and recovery runbook](docs/operations/health-and-recovery.md);
4. the platform guide for [Windows](docs/development/windows.md) or
   [macOS](docs/development/macos.md).

If the problem remains, search [existing
issues](https://github.com/DimLeon009/threat-claim-monitor/issues). If no issue
matches, open an [installation or usage help
request](https://github.com/DimLeon009/threat-claim-monitor/issues/new?template=help_request.yml).

Include the operating system, CPU architecture, Docker and Compose versions,
current commit or release, the exact step that failed, sanitized service status,
and a short bounded log excerpt. Replace secrets, organization data, victim
data, URLs containing tokens, and personal information with `[REDACTED]`.

## Reproducible defect

Open a [bug
report](https://github.com/DimLeon009/threat-claim-monitor/issues/new?template=bug_report.yml)
when documented behavior is reproducibly incorrect. State the expected and
actual behavior, minimal synthetic reproduction, deployment mode, affected
version, and safe rollback already attempted.

Do not use a bug report for a suspected security vulnerability.

## Feature or implementation work

- Use a [feature
  request](https://github.com/DimLeon009/threat-claim-monitor/issues/new?template=feature_request.yml)
  to explain an unmet operational need.
- Use an [implementation
  task](https://github.com/DimLeon009/threat-claim-monitor/issues/new?template=task.yml)
  for an agreed, bounded deliverable with acceptance criteria.
- Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing code, workflows,
  migrations, infrastructure, or documentation.

## Pull request

Open a pull request only for a reviewed change you are prepared to maintain.
Link the corresponding issue, keep one observable outcome per pull request,
complete the repository template, provide sanitized validation evidence, and
describe failure and rollback behavior. Never include a live `.env`, credential,
webhook signature, raw victim data, or a backup.

Start from the current `main` branch and follow the branch and validation rules
in [CONTRIBUTING.md](CONTRIBUTING.md). A pull request is not a support channel:
use an issue first when the required change is still unclear.

## Security vulnerability

Do not open a public issue or pull request. Use GitHub [private vulnerability
reporting](https://github.com/DimLeon009/threat-claim-monitor/security/advisories/new)
and follow [SECURITY.md](SECURITY.md). Use synthetic evidence and sanitized logs;
never attach malware, stolen data, active credentials, production backups, or
an exploit against a third-party system.

## What maintainers can reasonably support

The validated reference environments are Windows 11 and macOS on Apple Silicon.
Reasonable help includes repository installation, sanitized workflow imports,
documented database contracts, and reproducible defects. Cloud subscriptions,
enterprise n8n features, third-party SMTP or Teams administration, Internet
exposure, and production operations require the operator or organization that
owns those systems.
