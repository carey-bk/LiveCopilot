# Lessons

## JSONSerialization + OpenAI Realtime `threshold` — decimal places
- **Mistake:** Set VAD `threshold` to `0.3` (a Double). `JSONSerialization` renders `0.3` as `"0.29999999999999999"` (17 decimal places). The Realtime API rejects any number with >16 dp → `code=decimal_max_decimal_places_exceeded`, the `session.update` fails, the session never reaches `connected`, and ALL audio for that session is silently dropped (`sendAudio DROPPED (state=connecting)`).
- **Why it was sneaky:** `0.5` is exactly representable in binary so it printed clean → the "Them" session worked. Only the "You" (mic) session, which I'd given `0.3`, errored. Symptom looked like "mic/AEC problem" but was a serialization bug.
- **Rounding a Double does NOT fix it:** `(0.3*100).rounded()/100` is still the same non-representable `0.3`. The artifact is in how the float prints, not its "rounded" value.
- **Rule:** Any Double sent to the Realtime API as JSON must be exactly representable in binary FP. Safe: multiples of `0.25` / `0.5` (0.25, 0.5, 0.75). NOT safe: 0.1, 0.2, 0.3, 0.35, 0.4. When tuning `threshold`, stick to 0.25 steps. (Documented in Config.vadThreshold.)
- **Diagnosis win:** logging the `error` event's `code`/`param`/`message` to DebugLog (not just OSLog) immediately revealed it. Always surface server error bodies to the file log.
