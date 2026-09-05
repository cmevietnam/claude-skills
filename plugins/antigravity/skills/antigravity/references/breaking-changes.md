# Production breaking-change detection

**Mandatory:** when Antigravity analyses or applies changes that will be deployed to production,
append this block to the prompt.

```
Also check for PRODUCTION BREAKING CHANGES:
1. Does any change REJECT inputs previously ACCEPTED? (stricter validation, new required fields)
   → New validation must apply to CREATION paths only, NOT read/login/existing-data paths
2. Does any change INVALIDATE existing sessions/data? (token format, cache keys, Redis schema)
   → Flag if Redis restart wipes data, coordinated deploy needed
3. Does any change REMOVE or RENAME external-facing contracts? (API fields, endpoints, env vars)
4. Does any change affect EXISTING USERS differently than NEW USERS?
   → Example: password min-length on login blocks existing users with shorter passwords
5. Does any change require COORDINATED DEPLOY? (DB migration + code, Redis auth + API restart)

For each finding, state: WHAT breaks, WHO is affected, HOW to mitigate.
```

## The principle

Tightening validation on a READ or LOGIN path breaks existing users. Tighten on
WRITE/CREATE paths only, unless the existing data is migrated first.

## The incident behind it

CME Vietnam, 2026-04-12:

- A security fix raised the password minimum length from 6 to 8.
- It was applied to the login endpoint (a READ path) instead of only to registration
  (a WRITE path).
- Every existing user with a 6–7 character password was locked out of production.
- Fix: drop the length check from login; keep it on registration and password change.
