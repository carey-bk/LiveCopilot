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
- Recording/recognition: structured stages, process information, and exit information help locate startup/shutdown boundaries. About five seconds after listening starts (`audioCheck`) and when each source stops (`audioSummary`), the journal records per-source numbers only: whether any audio arrived (`noAudio`), whether it was exact digital silence (`digitalSilence`), whether audio produced no text (`audioWithoutText`), peak level, audible share, partial/final counts, provider-activity-event-to-next-text time (excluding delay before the provider reports activity; not end-to-end recognition latency) and the largest local recognition backlog. A microphone reconfiguration (`micDeviceChanged`) followed by `micReady` means capture recovered automatically; followed by `micStopped` it did not. A `micFailed` between them means the immediate restart failed and the one retry 0.5 s later decided the outcome.
- Recognition timing (local and Apple speech): `ready_ms` is how long the speech model took to load after listening started; `final_lag_ms_*` is how much audio had been captured after each utterance ended when its final text arrived (endpoint silence, queueing and inference included); `backlog_ms_max` is the most captured audio ever waiting for recognition. `speechFailed failure=speech_load_slow` means more than 12 s of audio queued while the model was still loading; `failure=speech_behind` means recognition could not keep up after it was ready.
- Local worker crashes: a native worker that exits while the app writes to it now ends listening with a visible error (`workerFailure` / `process_ended`) instead of terminating LiveCopilot silently.
- Crashes: deeper stack analysis requires the relevant `.ips` report and the author's matching-build dSYM. No `.ips` report does not mean no crash occurred.
- Hangs: the current ZIP does not automatically include a process sample from the hang; this must be collected separately.
- Answer quality, translation misalignment, and UI issues require concrete reproduction steps and screenshots. Logs intentionally omit recordings, conversations, knowledge-base content, and keys.
- `dispatched` means an automatic answer was submitted, not that it completed successfully. `disabled` after listening stops does not mean the user forgot to enable automatic suggestions.
