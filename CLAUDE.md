# LiveCopilot developer entry point

User requirements in `docs/livecopilot_goal.md` are the scope and acceptance authority for this task. This repository derives from Stealth; legacy architecture and code remain in upstream Git history.

Read `docs/ARCHITECTURE.md`, `docs/IMPLEMENTATION_PLAN.md`, and `docs/VERIFICATION.md` for the current architecture, progress and evidence boundaries.

- Native Swift/SwiftUI macOS app; no Electron/web rewrite or unrelated product scope.
- Preserve native capture, NSPanel, Carbon hotkeys, local history, Keychain and signing workflow.
- Official Live client delegation is separate from local RAG and Responses reasoning.
- Run `StealthApp/scripts/test-core.sh` and native build/XCTest after meaningful changes.
- No secrets, private documents, transcripts or runtime indexes in Git/logs. Keychain service is `LiveCopilot-OpenAI`, account current macOS username; environment fallback is `OPENAI_API_KEY`.
- Real integration is opt-in and uses synthetic fixtures. Do not claim hardware, UI or screen-share behavior without corresponding evidence.
