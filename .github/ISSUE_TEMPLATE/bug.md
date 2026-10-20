---
name: Bug
about: Something is broken or behaves differently than intended
title: "fix: <what is broken>"
labels: bug
type: Bug
---

<!-- Never paste credentials, tokens, account IDs or real client data. Use synthetic data or "[REDACTED — see <where>]". -->

## Description

<!-- What is broken, and who does it affect? -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

## Actual behavior

## Environment

- **Where:** <!-- prod, beta, pth-test (platform-tests), local -->
- **Version or commit:** <!-- image tag or commit SHA -->
- **Browser and OS (UI bugs):**

## Severity

- [ ] Critical: system down or data loss
- [ ] High: core function broken, no workaround
- [ ] Medium: impaired, a workaround exists
- [ ] Low: minor, cosmetic or an edge case

## Acceptance criteria

- [ ] The broken behavior no longer occurs
- [ ] A regression test covers it (a repo unit test, plus a platform-tests spec where behavior crosses services)

## Additional context

<!-- Logs, screenshots, related issues -->
