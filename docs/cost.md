# Cost

Two separate bills: the machine, and the model. Prices are in `data/pricing.json`, and
`python run_demo.py` recomputes everything below.

## The machine

The VM matches the desktop VM the agent ran on before (6 vCPU / 20 GB, 60 GB disk), so the
agent loses nothing in the move. Running it 24/7 would cost about **$148/month**.

Wake-on-demand pays for the disk all month and for compute only while awake. Replaying the
campaign (three scheduled posts a week plus about four Telegram conversations a week), the
VM is awake **5.3%** of the time:

| | VM hours/month | Compute | Disk | Total |
|---|---:|---:|---:|---:|
| Always on | 730 | $141.86 | $6.00 | **$147.86** |
| Wake-on-demand | 38 | $7.47 | $6.00 | **$13.47** |

The waker, the Scheduler job and the secret fit in GCP's free tiers. Each extra awake hour
costs about $0.19, so heavier interactive use moves the total, but not the order of
magnitude.

## The model

Hermes routes all routine work to **DeepSeek V4 Flash via OpenRouter**
(`hermes/config.example.yaml`), with a free model and Gemini Flash as fallbacks.

DeepSeek V4 Flash was chosen in a bake-off on the agent's actual work: LinkedIn copy,
market reasoning and tool calling across five candidate models. It scored highest overall,
passed all three tasks, and was the fastest and the cheapest of the paid models. A free
candidate errored on every task; another model returned empty output on 2 of 3.

The campaign's scheduled runs per month, under the same illustrative token profile
(`data/token_profiles.json`) for every model:

| Model | $/month | vs DeepSeek |
|---|---:|---:|
| DeepSeek V4 Flash | 0.50 | 1× |
| Claude Haiku 4.5 | 4.95 | 10× |
| Claude Sonnet 5.5 | 9.21 | 19× |
| Claude Opus 5.5 | 18.42 | 37× |

The token profile is illustrative. Replace it with your own usage, which Hermes records per
session in `~/.hermes/state.db`, and the table updates. The ratio is the robust part: it
comes from the per-token prices, not the profile. Agentic browser runs are input-heavy
(page snapshots, tool results), so the input and cache-read prices dominate.

Claude is still in the system, as the boss. It writes the handoffs, skills and prompts
that let the cheap model succeed, and its cost is paid once per change instead of once per
run. See [boss-implementer.md](boss-implementer.md).
