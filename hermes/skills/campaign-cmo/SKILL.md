---
name: campaign-cmo
description: Run a B2B LinkedIn campaign for a company page. Read the campaign master plan, research and write commentary posts, schedule posts through the logged-in browser, and report back on Telegram. Includes the recovery procedure for a missed scheduled run.
version: 1.1
tags: [marketing, linkedin, content, browser-automation, cron]
---

# Campaign CMO

A condensed, sanitized version of the production skill. Hermes patched the production
skill 144 times while it worked: every pitfall below is something it hit and wrote
down for its next run.

## Inputs

- `~/campaign/master-plan.md`: the authoritative schedule. One entry per post, headed
  `### TUE Jun 2 — <theme>`. Each entry carries either final copy (post exactly as
  written) or a research brief (topic, angle, hashtags). An entry marked
  `[ALREADY POSTED NO ACTION NEEDED]` is skipped.
- `~/campaign/images/`: images referenced by entries.
- Chrome over CDP at `127.0.0.1:9222`, already logged in as a page admin.

## Weekly rhythm

| Day | Type | What the agent does |
|-----|------|---------------------|
| Tue | Campaign post | Posts the pre-written copy as-is and flags the image to attach |
| Thu | Industry commentary | Researches the brief, writes 150–200 words, then schedules |
| Sat | Educational | Posts the pre-written copy as-is |

Commentary structure: one concrete, sourced 2025–2026 data point → what it means for CIOs
→ one closing question → the brief's exact hashtags. Prefer local sources for regional
topics. Put the source in the Telegram confirmation, not in the post.

## Scheduling a post (LinkedIn page admin)

1. Open `linkedin.com/company/<PAGE_ID>/admin/page-posts/published/`.
2. "Start a post" → click the textbox → type the full text.
3. "Schedule post" (not "Post") → confirm the date is today → "Next" → "Schedule".
4. Wait for the "Post scheduled." toast before reporting success.

Known limits; don't spend turns fighting them:
- The time picker is React-controlled and ignores synthetic input. Accept the default time.
- Image upload opens the native OS file picker, which CDP can't drive. Schedule the text,
  then report `📷 Image to attach: <file>` so the owner adds it.
- A past date can't be scheduled. A make-up post goes out today.
- If the session has expired, don't attempt a login. Deliver the post text so the owner
  can post it, and ask them to run `hermes-chrome-relogin` from the remote desktop.

## Browser or API?

APIs first. The browser is for things that have no API (LinkedIn page admin, partner
marketing portals). Stop after three failed browser attempts at the same step and report
back. On SPAs whose accessibility tree is empty, a screenshot read by the vision model
beats blind clicking, and `Runtime.evaluate` beats `browser_click`.

## Working style

- Do the homework before claiming a limitation: check the available tools and skills first.
- When the owner says a result is wrong, re-read the request instead of defending the answer.
- Batch independent research through delegated sub-agents. Stop on diminishing returns.

## When a scheduled run was missed

The Hermes scheduler waits `grace=7200s` past a missed slot. If the gateway still isn't
up after that, it fast-forwards to the next occurrence and never catches up. To diagnose:

```bash
hermes cron list                                   # last_run_at / next_run_at
ls ~/.hermes/cron/output/<job_id>/                 # one file per run
grep -a "missed its scheduled time" ~/.hermes/logs/agent.log
```

To recover, post the missed entry by hand (today's date). The job state stays
fast-forwarded, which is expected.

On the GCP deployment this shouldn't happen: Cloud Scheduler starts the VM 8 minutes before
every due job. See `docs/architecture.md`.
