# Shortcuts Agent Integration (Option 1)

This branch exposes two App Intents so Apple Shortcuts can orchestrate the agent loop while the app only provides a browser snapshot and an action executor. There is no in-app LLM loop and no backend dependency.

## Available App Intents

1. **GetBrowserSnapshotIntent** (Shortcuts title: *Get Telescopure Snapshot*)
   - Returns a PNG of the visible `WKWebView`, current URL, document title, viewport width/height (pixels), and an optional text snippet (first ~2000 chars of `document.body.innerText` with whitespace normalized).
   - Parameter: `includeTextSnippet` (Bool, default `true`).
   - Errors clearly when no active tab is available.

2. **ExecuteBrowserActionsIntent** (Shortcuts title: *Execute Telescopure Browser Actions*)
   - Input: `actionsJson` following the schema below.
   - Optional parameters:
     - `requireConfirmationOnRisky` (Bool, default `true`) pauses if the page contains risky words.
     - `maxActions` (Int, default `10`) caps how many actions run per call.
   - Output: `executedCount`, `skippedCount`, `errors` (array), `warnings` (array), `finalURL`, `finalTitle`, `didNavigate` (Bool).
   - Performs a safety scan before executing actions. Keywords: purchase, buy, pay, checkout, send, post, delete, confirm, submit order, authorize, install.

## JSON schema for `actionsJson`

```json
{
  "actions": [
    {
      "type": "navigate",
      "url": "https://example.com"
    },
    {
      "type": "click_at",
      "x": 500, "y": 260
    },
    {
      "type": "scroll",
      "deltaY": 800
    },
    {
      "type": "type",
      "text": "hello world"
    },
    {
      "type": "wait",
      "ms": 1000
    }
  ],
  "done": false,
  "note": "optional description"
}
```

- `type` must be one of `navigate | click_at | scroll | type | wait`.
- `click_at` uses normalized coordinates (0–1000) mapped to the visible viewport; values are clamped into that range.
- `scroll` uses pixel delta for Y only.
- `type` appends to the focused element (falls back to center/top elements) and dispatches `input` + `change` events.
- `wait` delays in milliseconds.

## Example Shortcut loop

1. Ask the user for a Goal.
2. Repeat for N steps or until the LLM says done:
   - Call **Get Telescopure Snapshot** (optionally skip text for speed).
   - Send the snapshot, URL, title, viewport, and snippet to an LLM (ChatGPT action or HTTP request). Prompt it to respond with the JSON schema above.
   - Parse/clean the JSON (Shortcuts `Get Dictionary from Input` + `Get Value for Key actions`).
   - Call **Execute Telescopure Browser Actions** with the JSON text and optional safeguards (set `maxActions` and `requireConfirmationOnRisky`).
   - Wait briefly (e.g., 1–2 seconds) before the next iteration.
3. Stop when `done` is set or goals are reached.

## Limitations

- Shortcuts execution time limits may stop long loops; keep action batches short and reuse `maxActions`.
- WKWebView click simulation uses `elementFromPoint` plus pointer/mouse events; some sites may block or require precise coordinates.
- Programmatic typing focuses the active element or nearby candidates; pages with custom inputs may ignore injected values.
- Only the in-app web view is automated—no system-wide automation or background browsing.
- If no page is loaded, intents return descriptive errors instead of crashing.
