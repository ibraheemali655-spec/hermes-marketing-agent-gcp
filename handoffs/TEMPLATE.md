# Implementation Handoff: <one-line goal>

**Author:** boss (Claude) · **Implementer:** <model / agent> · **Status:** draft | approved by owner

> Implementer: execute on <host> (<how to reach it>). Go phase by phase and stop at each
> **GATE** until it passes. Don't print secrets. Escalate anything in section 6 instead of guessing.

## 1. Why
The outcome the owner wants, in two or three sentences. Not the method.

## 2. Ground truth (verified, don't re-derive)
Facts the boss has already checked: paths, versions, service names, IDs (as placeholders),
current config. Every line here saves the implementer an exploration loop on a cheap model.

## 3. Gotchas (read before starting)
What will go wrong if done the obvious way. Each one is a past failure or a known trap,
e.g. "never run two gateways on one bot token: duplicate posts".

## 4. Phases
### Phase A: <non-disruptive build step>
1. …
### Phase B: <prepare, don't activate>
### Phase C: <cut over, smallest possible gap>

### GATE: verify before declaring done
- A command plus the output it must show, one per claim.
- At least one check that proves *the point* of the change, not just that services are up.
- Reboot survival, if the change touches boot.

### Phase D: update the repo
Which scripts and docs change, then commit with a conventional message. Secrets check
(`git status`, `git diff --cached`) before every commit.

## 5. Definition of done
One paragraph the owner could check without reading the diff.

## 6. Escalate to owner
Decisions that aren't the implementer's to make (privilege, cost, data loss, anything
customer-visible).
