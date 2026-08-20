---
name: macos-process-measurement
description: >-
  Measures how much CPU a running process actually uses on macOS, for benchmarks
  and A/B comparisons. Use whenever the task is to measure, profile, benchmark or
  compare the CPU cost of a running process or GUI app on macOS — "how much CPU
  does X use", "is this change faster", "profile the app", "compare before/after",
  "why is it pegging a core" — and whenever you are about to reach for
  `ps -o %cpu`, `top`, or `time` to answer such a question. Also use when
  interpreting a CPU number that looks suspiciously low for a windowed app.
---

# Measuring process CPU on macOS

`ps -o %cpu` is **not** current utilisation — it is a decayed average over the process's whole
lifetime, so a few seconds of startup cost keeps skewing it long after the process settled, and
two runs of different lengths are not comparable. Sample cumulative CPU *time* at two points and
divide by the wall clock between them instead:

```
c1 = cputime(pid); t1 = now()
sleep(window)
c2 = cputime(pid); t2 = now()
cpu_percent = (c2 - c1) / (t2 - t1) * 100
```

`ps -o cputime= -p <pid>` gives `[[HH:]MM:]SS.ss`. Warm up first — JIT, shader compilation and
codec setup all land in the first seconds and are not what is being measured.

## Two things that quietly invalidate a result

- **Occlusion throttling.** macOS throttles rendering in windows that are covered or minimised,
  so a GUI app measured behind a terminal reports a beautifully low number that means nothing.
  Keep the window frontmost, and record a throughput figure (frames rendered per second, requests
  served) alongside the CPU figure — a low CPU reading is only interpretable next to evidence
  that the work actually happened.
- **Comparing at different throughput.** If one variant hits 60 fps and the other drops to 56,
  their raw CPU numbers are not comparable; normalise to cost-per-unit-of-work, and report the
  throughput difference separately since it is usually the thing the user actually cares about.

Repeat the whole comparison two or three times before reporting. A surprising result that
reproduces exactly is a finding; one that moves between runs is noise.
