# Privacy (152-FZ, GDPR health data)

Reviewer: `privacy-compliance-reviewer`. These rules are not negotiable in code review.

1. **Never log medical data.** Medication names/forms/strengths/notes, schedules/rules, dose events, stock,
   adherence, report contents must not appear in logs, exceptions, Sentry, AppMetrica, metrics labels,
   push payloads, email subjects or URLs. Log opaque UUIDs, route templates, status, latency, error codes.
2. **Personal data minimised in logs**: no passwords, tokens, codes, full emails, IPs beyond rate-limit use.
3. **Region localization.** One codebase, one deployment per region (`REGION=ru|eu`), separate PostgreSQL,
   Redis, Sentry and analytics per region. RU citizens' data stays in RU (152-FZ). No shared or replicated
   stores across regions, no cross-region backups or queues.
4. **No cross-region links.** Relatives, grants and invites only inside one region.
5. **Per-medication privacy** (`shared` / `anonymous` / `hidden`) is enforced server-side on every
   relative-facing path (API, sync pull, missed-dose push, shared PDF). `anonymous` exposes time + status only.
6. **Consent.** Explicit, separate consent for health data, stored with version and timestamp.
7. **Deletion and export** cover every table holding personal or medical data; new tables must be added to both.
8. **Third parties** are listed per region. Ads never on reminder/dose screens and never get medical context.
9. **Test data** is synthetic. No real names, emails or prescriptions in fixtures, vectors, docs or screenshots.
