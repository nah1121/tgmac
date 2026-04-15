# BackupBot Audit (Done in a Bad Mood)

Date: 2026-04-15

## Executive Summary

This codebase talks like production software and behaves like a prototype wearing a fake mustache. The biggest risk is that key auth/upload paths are still stubbed or logically unsafe, while the UI and README imply a complete Telegram backup product.

## High Severity Findings

1. **Build is currently broken in this environment**
   - `swift test` fails immediately because the package imports `SwiftData`, which is unavailable in this Linux CI/container environment.
   - Impact: no test confidence and no reproducible CI gate outside macOS/Xcode.

2. **MTProto response routing is incorrect under concurrency**
   - Transport receives a message and resumes *all* pending continuations with the same payload instead of matching by message ID.
   - Impact: request/response cross-talk, data corruption, random auth/upload behavior under parallel or rapid requests.

3. **“Production transport” still contains protocol-critical placeholders**
   - Receive path comments explicitly note placeholder decryption and buffer-consumption behavior.
   - Impact: protocol fragility, undefined behavior on fragmented frames, and security correctness risk.

4. **Client upload flow returns fake success values**
   - Upload code returns a random message ID rather than parsing server `Updates` response.
   - Impact: false-positive success and broken downstream tracking/integrity guarantees.

## Medium Severity Findings

5. **Credential handling is inconsistent with the UI promise**
   - UI footer claims credentials are stored securely in Keychain, but API ID/hash are persisted using `@AppStorage` (UserDefaults-backed), while Keychain is used elsewhere.
   - Impact: sensitive values may sit in less-protected local preferences.

6. **Unsafe force unwraps in folder save path**
   - `bookmarkData!` is force-unwrapped twice in save flow.
   - Impact: avoidable crash surface if state gets out of sync.

7. **Session persistence code quality issues**
   - Session load paths use `guard let data = try KeychainHelper.load(...)` even though helper returns non-optional `Data`.
   - Impact: internal API contract mismatch, likely dead/incorrect code paths and poor maintainability.

## Low Severity / Architecture Debt

8. **Config says “maxConcurrentUploads”, implementation is effectively serialized with retry loops**
   - Design is not inherently bad, but naming and expectations are misleading.

9. **README overstates implementation maturity**
   - Documentation markets full MTProto stack while core client and transport still include many TODOs/placeholders.

## Recommendations (Prioritized)

1. **Make transport correctness non-negotiable before feature work**
   - Implement strict message-ID correlation for pending requests.
   - Replace placeholder decrypt/dispatch logic with complete frame parsing.

2. **Stop pretending upload completion is real**
   - Parse and return canonical server message identifiers; fail hard if unavailable.

3. **Unify secret storage policy**
   - Move API hash (and likely API ID/phone metadata policy review) to Keychain.
   - Update UI text to reflect actual behavior until migration is done.

4. **Remove all force unwraps in persistence/auth flows**
   - Replace with guard + user-visible error states.

5. **Split platform-specific code for real CI**
   - Gate SwiftData-dependent targets for macOS only or provide abstraction so Linux CI can still run core service tests.

## Tone-adjusted Verdict

If this were a PR from Claude, I’d block it. Too many “looks done” surfaces with “not done” internals, especially around protocol handling and upload truthfulness.
