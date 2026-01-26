# Expert Index

Domain experts that provide specialized guidance. Load the relevant expert based on task keywords.

## Keyword Routing

| Keywords | Expert File | Primary Persona |
|----------|-------------|-----------------|
| `api`, `schema`, `scalability`, `systems`, `microservice` | architecture.md | Systems Architect |
| `auth`, `security`, `GDPR`, `HIPAA`, `encryption`, `vulnerability` | security.md | Security Engineer |
| `test`, `QA`, `coverage`, `e2e`, `unit`, `integration` | testing.md | QA Engineer |
| `code`, `refactor`, `implement`, `debug`, `audit` | implementation.md | Senior Developer |
| `deploy`, `CI/CD`, `docker`, `k8s`, `infra`, `SRE` | devops.md | DevOps Engineer |
| `UI`, `UX`, `design`, `accessibility`, `a11y` | design.md | UX Designer |
| `docs`, `README`, `changelog`, `runbook` | documentation.md | Technical Writer |
| `product`, `requirements`, `MVP`, `scope`, `user story` | product.md | Product Manager |

## Loading Experts

Experts provide *guidance*, while Skills provide *procedures*.

**In AGENTS.md context**:
```markdown
<!-- Load expert for security-related task -->
Before implementing auth changes, consult: system/experts/security.md

<!-- Load expert for testing task -->
For test strategy, consult: system/experts/testing.md
```

**In loop prompts**:
Include relevant expert file contents via PROMPT_*.md templates.

## Expert vs Skill

| Aspect | Expert | Skill |
|--------|--------|-------|
| Purpose | Guidance, review, strategy | Execution, procedures |
| Output | Recommendations, concerns | Commands, code changes |
| When | Before/during decisions | During implementation |
| Format | Personas with knowledge | Step-by-step instructions |

## Customization

Projects can override experts by creating `system/experts/<file>.md` in the target repo. The local version takes precedence over the template.
