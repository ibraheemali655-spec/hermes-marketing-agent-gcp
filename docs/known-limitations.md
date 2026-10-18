# Known limitations

**The simulation's laptop is synthetic.** `run_demo.py` replays the campaign against a
seeded on/off pattern for a laptop, not a recorded one. It's calibrated so the desktop misses
about 1 post in 10, close to what the real desktop host did (one silent miss in its first
eight scheduled runs). The GCP result (no misses) doesn't depend on that calibration. It
follows from the VM being started before every slot.

**Wake-on-demand costs depend on how you use it.** The cost table assumes about four Telegram
conversations a week. Long interactive sessions keep the VM awake, at about $0.19 per hour.
Leaving a remote-desktop session connected keeps it awake indefinitely.

**The model token profile is illustrative.** `data/token_profiles.json` is a stand-in.
Hermes records real per-session usage in `~/.hermes/state.db`, which this repo doesn't
publish. The model-to-model ratios come from list prices and hold for any profile with the
same input/output mix.

**Cold start is about 60 seconds.** A Telegram message to a sleeping VM wakes it, but that
message isn't processed. The waker asks you to resend it once the "ready" ping arrives.

**One posting time.** LinkedIn's scheduling time picker can't be driven by automation, so
posts land at the default time LinkedIn offers. The date is right.

**Images are attached by a human.** Same reason: the OS file picker.

**Session expiry is a manual step.** The agent won't enter passwords. Re-login is
`hermes-chrome-relogin` from the remote desktop.

**The waker is a public endpoint.** Telegram has to reach it. `/telegram` checks Telegram's
secret header and `/wake` checks a shared token. The worst an attacker without either can do
is get a 403.

**Single VM, single zone.** No failover: a zonal outage delays posts until the zone is back.
That's acceptable for a three-posts-a-week campaign, but not for anything customer-facing.
