# Boss and implementer

The system runs two kinds of agent, and they don't do the same job.

| | Boss | Implementer |
|---|---|---|
| Who | Claude (Claude Code, on the operator's machine or the VM) | Hermes, on a cheap model (DeepSeek V4 Flash) |
| When | When there's something to design, change or review | Around the clock, on a schedule or a Telegram message |
| Does | Plans; writes handoffs, skills and cron prompts; reviews diffs and results | Executes: reads the plan, researches, drives the browser, posts, reports |
| Costs | Frontier price, but used rarely | Fractions of a cent per run, used constantly |
| Leaves behind | A handoff with gates; a skill; a prompt | A Telegram report; a cron output file; patches to its own skill |

The split exists because the two jobs fail differently. Planning fails when the model
misses a constraint: that needs the strongest model, and it's needed rarely. Execution
fails on missing context: a cheap model does fine **if** the boss has already written
down what it would otherwise spend 40 tool calls discovering.

## The contract: a handoff

The boss never says "go migrate the agent". It writes a handoff
([TEMPLATE.md](../handoffs/TEMPLATE.md)) with:

- **Ground truth**: facts already verified, so the implementer doesn't re-derive them on a
  cheap model.
- **Gotchas**: the traps, each one a past failure. For example: never run two gateways on
  one bot token, because Telegram returns 409 and every cron job fires twice (duplicate
  LinkedIn posts).
- **Phases with a GATE**: commands plus the output they must show. At least one check
  proves the *point* of the change, not just that services are up.
- **Escalations**: decisions that stay with the owner (privilege, cost, data loss).

[example-native-runtime.md](../handoffs/example-native-runtime.md) is a real one from
building this system: Claude Opus specified moving Hermes from Docker to native systemd
services so the agent could reach the whole machine, and GLM implemented it. The result is
`infra/vm/install-hermes-native.sh`.

## At runtime

The same split governs the marketing work.

- **The plan** (`hermes/campaign/master-plan.example.md`) and **the skill**
  (`hermes/skills/campaign-cmo/SKILL.md`) are written in deliberate sessions with the owner.
  The skill holds the hard-won knowledge: the LinkedIn time picker can't be automated, so
  accept the default; image upload needs the OS file picker, so flag the file for the owner.
- **The cron prompts** (`hermes/cron/jobs.example.json`) are short, procedural and checkable:
  find today's entry, skip it if it's marked posted, schedule it, report in a fixed format.
  A cheap model following a tight script is reliable. The same model improvising is not.
- **The implementer writes back.** Hermes patched its production skill 144 times. Each patch
  recorded a pitfall it hit (a SPA whose accessibility tree is empty, an expired session, a
  missed run), so the next run doesn't hit it again. The boss reviews those patches, and the
  good ones become ground truth for the next handoff.

## Why this is cheap

The expensive model's work is front-loaded and amortized. One handoff or skill revision is
reused by every scheduled run that follows. The cheap model's work recurs, and at
$0.091 / $0.182 per million tokens it's about 10× cheaper than Claude Haiku 4.5 and about
37× cheaper than Claude Opus 5.5 on the same token profile (see [cost.md](cost.md)).
