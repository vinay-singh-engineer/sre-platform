# Postmortem Template

**This template follows the blameless postmortem practice from the Google SRE Book.**
Focus is on systems and processes, not individuals.

---

## Incident Summary

| Field | Value |
|:---|:---|
| **Incident ID** | INC-YYYY-NNN |
| **Date** | YYYY-MM-DD |
| **Duration** | HH:MM — HH:MM UTC (X minutes) |
| **Severity** | SEV-1 / SEV-2 / SEV-3 |
| **Affected service** | `sre-platform` |
| **Impact** | X% error rate for Y minutes. ~Z users affected. |
| **Error budget consumed** | X% of monthly budget |
| **Incident commander** | @name |
| **Author(s)** | @name, @name |
| **Review date** | YYYY-MM-DD |
| **Status** | Draft / In Review / Approved |

---

## Impact

Describe the user-facing impact in concrete terms.

- What broke? What worked?
- How many requests failed?
- Were any users unable to complete their tasks?
- Was this a full outage or partial degradation?

**Example:** "From 14:23–14:47 UTC, approximately 12% of API requests returned HTTP 500. Users
creating items experienced failures. Read operations were unaffected. ~1,800 requests failed."

---

## Timeline

All times in UTC.

| Time | Event |
|:---|:---|
| HH:MM | Deployment of `v1.2.3` to EKS (GitHub Actions run #NNN) |
| HH:MM | `SLOErrorBudgetBurnRateCritical` alert fired (14.4× burn rate) |
| HH:MM | On-call engineer acknowledged PagerDuty alert |
| HH:MM | Engineer confirmed 5xx on `/api/items POST` endpoint |
| HH:MM | Identified root cause: OOM in container due to unbounded in-memory list |
| HH:MM | Rollback to `v1.2.2` initiated |
| HH:MM | ECS service stable, error rate returned to baseline |
| HH:MM | All-clear declared |

---

## Root Cause

Describe the technical root cause. Be specific. Include the triggering condition
and the contributing factors.

**Example:** "A new endpoint in v1.2.3 read the entire items collection into memory
before paginating, causing tasks to OOM when the collection exceeded ~5,000 items.
The deployment health check (which used a minimal dataset) did not catch this."

---

## Contributing Factors

List conditions that made the incident worse or harder to catch.

- [ ] No load test covering dataset sizes > 100 items
- [ ] Auto-scaling configured for CPU but not memory
- [ ] Deployment smoke test used a fresh environment (empty DB)

---

## Detection

How was the incident detected? How long after the start?

- Alert: `SLOErrorBudgetBurnRateCritical` fired X minutes after first error
- Was detection time acceptable? If not — what would have caught it earlier?

---

## Resolution

What specific action stopped the bleeding?

---

## What Went Well

Blameless postmortems celebrate things that worked.

- Alert fired within 2 minutes of SLO breach
- Rollback procedure was documented and took < 5 minutes
- On-call response time was fast

---

## What Went Wrong

- No representative load test in CI pipeline
- OOM restart loop delayed alert by 3 minutes (tasks restarting looked healthy to health check)

---

## Action Items

Each action item must have an owner and a due date. Use your issue tracker.

| # | Action | Owner | Due date | Ticket |
|:---|:---|:---|:---|:---|
| 1 | Add load test with 10k items to CI pipeline | @eng-name | YYYY-MM-DD | #NNN |
| 2 | Configure ECS task memory alarm in CloudWatch | @sre-name | YYYY-MM-DD | #NNN |
| 3 | Add memory-based auto-scaling policy | @sre-name | YYYY-MM-DD | #NNN |
| 4 | Update smoke test to pre-populate test data | @eng-name | YYYY-MM-DD | #NNN |

---

## Lessons Learned

Write 2–3 sentences describing the most important takeaway for the team.
What should everyone internalize from this incident?

---

*This postmortem was authored following the blameless practice described in
[Site Reliability Engineering](https://sre.google/sre-book/postmortem-culture/), Chapter 15.*
