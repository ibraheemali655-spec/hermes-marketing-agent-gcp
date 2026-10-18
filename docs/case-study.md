# Case study: a 10-week LinkedIn campaign for a client

The client, a small IT consultancy, had ready-made campaign assets (copy, banners, emails)
and no one with time to run a steady LinkedIn presence. Hermes ran it.

## The campaign

- **30 posts over 10 weeks**, May 19 to July 25, 2026: Tuesday campaign posts, Thursday
  industry commentary, Saturday educational posts.
- **Three waves**, each built on a vendor campaign: an enterprise agent platform, an
  enterprise AI app, and the agentic workplace.
- **Thursday commentary was original**: each brief named a regional topic (banking AI,
  telecom, AI governance, fintech, …). The agent researched it, found one
  concrete 2025–2026 data point, and wrote 150–200 words ending in a question.

## What a run looks like

A Thursday commentary run, as delivered to Telegram (structure kept, content summarized):

> **Posted: Thu May 21, 2026 — Banking & AI ✅**
> LinkedIn toast shows "Post scheduled." Post content (195 words): a recent central-bank
> AI-skills initiative as the opening data point → what it means for CIOs modernizing
> banking operations → a closing question asking which AI capability readers prioritize.
>
> **Research source:** the regulator's January 2026 announcement, via a national business daily.
> **Time note:** scheduled at LinkedIn's default time (the time picker can't be automated).

Each run reads the master plan, does the work, schedules the post in the logged-in browser,
and reports in a fixed format. When the plan says an entry is already posted, it says so and
stops.

## What broke, and what it changed

- **Missed post, 30 May.** The laptop hosting the agent's VM was off that Saturday morning.
  Hermes's scheduler waited out its 2-hour grace, then fast-forwarded the job to the next
  Saturday. The agent diagnosed the miss from its own logs and scheduled the post the next day, when asked. **This is why the agent moved to GCP**:
  a Cloud Scheduler wake 8 minutes before every job takes the laptop out of the loop.
- **A failed Thursday run, 4 June**, with no model output at all. Single failures like this are
  why every job reports to Telegram, success or not. Silence is itself a signal.
- **Images.** LinkedIn's upload opens the OS file picker, which browser automation can't drive.
  The agent schedules the text and names the image to attach; the owner attaches it.
- **Post time.** The scheduler's time picker ignores synthetic input, so posts go out at
  LinkedIn's default time on the right day.

All four are written into the skill ([SKILL.md](../hermes/skills/campaign-cmo/SKILL.md)), so
no later run has to discover them again.
