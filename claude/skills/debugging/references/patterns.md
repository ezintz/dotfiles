# Debugging Reference Patterns

Situational triage trees and code patterns. Consult the section that matches
what you're looking at; this file isn't meant to be read start to end.

## Error-Specific Patterns

### Non-Reproducible Bug Triage

```
Cannot reproduce on demand:
├── Timing-dependent?
│   ├── Add timestamps to logs around the suspected area
│   ├── Try with artificial delays (timeout, sleep) to widen race windows
│   └── Run under load or concurrency to increase collision probability
├── Environment-dependent?
│   ├── Compare versions, OS, environment variables
│   ├── Check for differences in data (empty vs populated database)
│   └── Try reproducing in CI where the environment is clean (NO real data)
├── State-dependent?
│   ├── Check for leaked state between tests or requests
│   ├── Look for global variables, singletons, or shared caches
│   └── Run the failing scenario in isolation vs after other operations
└── Truly random?
    ├── Add defensive logging at the suspected location
    ├── Set up an alert for the specific error signature
    └── Document the conditions observed and revisit when it recurs
```

### Test Failure Triage

```
Test fails after code change:
├── Did you change code the test covers?
│   └── YES → Check if the test or the code is wrong
│       ├── Test is outdated → Update the test
│       └── Code has a bug → Fix the code
├── Did you change unrelated code?
│   └── YES → Likely a side effect → Check shared state, imports, globals
└── Test was already flaky?
    └── Check for timing issues, order dependence, external dependencies
```

### Build Failure Triage

```
Build fails:
├── Type / compile error → Read the error, check the types at the cited location
├── Import error → Check the module exists, exports match, paths are correct
├── Config error → Check build config files for syntax/schema issues
├── Dependency error → Check the manifest and lockfile, reinstall
└── Toolchain error → Check the language/runtime version, OS compatibility
```

### Runtime Error Triage (web/JS)

```
Runtime error:
├── TypeError: Cannot read property 'x' of undefined
│   └── Something is null/undefined that shouldn't be
│       → Check data flow: where does this value come from?
├── Network error / CORS
│   └── Check URLs, headers, server CORS config
├── Render error / White screen
│   └── Check error boundary, console, component tree
└── Unexpected behavior (no error)
    └── Add logging at key points, verify data at each step
```

## Temporary Mitigations (Production Incidents Only)

These are for a live production incident where users are affected and the root
cause is not yet known. They are not a time-pressure shortcut on ordinary work —
Step 4 covers that case, and the symptom fix it rejects looks exactly like these.

A mitigation buys time; it does not close the bug. The reproduction and the
root-cause work stay open, and Step 5's regression test must target the
underlying cause, never the fallback.

Safe default plus a loud warning, instead of crashing on missing config. The
warning is the load-bearing part — a fallback that returns quietly is a silent
failure, and you will not find it again:

```typescript
function getConfig(key: string): string {
  const value = process.env[key];
  if (value === undefined) {
    console.warn(`Missing config ${key} — falling back to default`);
    return DEFAULTS[key] ?? '';
  }
  return value;
}
```

Graceful degradation, instead of one broken component taking down the view:

```typescript
function renderChart(data: Point[]): ChartView {
  if (data.length === 0) {
    return emptyState('No data available for this period');
  }
  try {
    return chart(data);
  } catch (error) {
    logError('Chart render failed', error);
    return errorState('Unable to display chart');
  }
}
```

Note where the `try` sits: around the call that can throw, not around a whole
render tree. In React and similar frameworks a `try`/`catch` wrapped around
returned markup will not catch errors thrown during rendering — that needs an
error boundary.
