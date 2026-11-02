# Reporting a problem to the author

For private troubleshooting, provide **LiveCopilot-support.zip**. The ZIP already includes the summary, so a separate TXT is unnecessary. For a public GitHub Issue, use a reviewed **LiveCopilot-diagnostics.txt** summary. Do not publicly post a ZIP containing raw crash reports.

1. Export diagnostics immediately after reproducing the problem. Do not restart the app or start another listening session first: doing so resets the automatic-trigger counters for that session.
2. Open Report a Problem → Export Detailed ZIP for private troubleshooting.
3. Enter the occurrence time and time zone, steps, expected and actual behavior, and microphone/headphone type. For a crash, select the report matching that time and explicitly include it.
4. Click “Export ZIP…” at the bottom right and choose a save location.
5. Review the saved ZIP in Finder, then send it through a private channel agreed with the author. The app does not send it automatically.
6. “Close” only closes the window. It does not save the description, export a file, or send feedback.

Include a relevant screenshot or short screen recording, avoiding private meeting content, keys, and account information.

## Current coverage

- Automatic answers: configuration, stage counters, and the latest 32 events without transcript text help narrow the problem to submission, scoring, or subsequent waiting stages. They do not include per-question text or complete correlated tracing.
- Recording/recognition: structured stages, process information, and exit information help locate startup/shutdown boundaries.
- Crashes: deeper stack analysis requires the relevant `.ips` report and the author's matching-build dSYM. No `.ips` report does not mean no crash occurred.
- Hangs: the current ZIP does not automatically include a process sample from the hang; this must be collected separately.
- Answer quality, translation misalignment, and UI issues require concrete reproduction steps and screenshots. Logs intentionally omit recordings, conversations, knowledge-base content, and keys.
- `dispatched` means an automatic answer was submitted, not that it completed successfully. `disabled` after listening stops does not mean the user forgot to enable automatic suggestions.
