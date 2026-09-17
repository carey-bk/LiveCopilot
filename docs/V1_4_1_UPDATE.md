# LiveCopilot 1.4.1 — Developer ID & Apple notarization

> Release gate: both the application and final DMG must be Accepted by Apple, with validated stapled tickets and successful Gatekeeper assessments before publication. Submission receipts accompany the GitHub Release.

## 中文

- 正式 Developer ID 签名：应用、原生推理程序、ONNX 与 llama 依赖采用同一开发者团队，启用 Hardened Runtime 和安全时间戳。
- 分别公证应用及最终 DMG，将 Apple 票据附加到两者，支持离线票据检查。
- 沿用 1.4.0 功能与数据。首次从旧临时签名迁移可能需重新允许录屏或钥匙串访问；以后保持同一团队和 bundle ID，不通过弱化验证来绕过系统授权。
- 发布脚本增加完整二进制检查、公证与 Gatekeeper 验证，并在 DMG 附加票据后重新计算校验和。旧的自签名根证书创建脚本改为只读身份检查。

## English

- Developer ID signing for the app and all bundled inference binaries, with secure timestamps and hardened runtime enabled for both Apple Silicon and Intel.
- Separate Apple notarization and stapled tickets for the application and final disk image.
- Retains 1.4.0 functionality and user data. The first migration from ad-hoc signing can require renewed recording or Keychain permission; subsequent builds preserve the developer team and bundle identity without bypassing macOS policy.
- Release tooling verifies every binary, app/DMG tickets and Gatekeeper, then recalculates checksums after stapling. The former self-signed-root setup is now read-only.

## Validation

- Universal Release build passed; 24 native XCTest cases passed, with zero failures.
- All 5 bundled Mach-O binaries / 10 architecture slices passed Developer ID, team consistency, timestamp and hardened-runtime verification. No debug, unsigned-memory or library-validation exception was added.
- Real signed local runtime passed Paraformer Chinese/English streaming, question triggers, silence/flush checks and BGE-M3 retrieval/index persistence. No paid API or physical microphone/system-audio capture was used.
- Signing continuity check passed: changing the build and re-signing with this Developer ID preserved the Apple-anchored designated requirement used by the local installer.
- Application notarization: Accepted, submission `f751b64b-f701-4f4c-8b9c-ef7da17ecf54`. The final DMG submission and distribution verification are recorded in `NotarizationInfo.txt` alongside the published download and checksums.
