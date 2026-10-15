# Current work

- Goal: merge PR #5, publish v0.2.1, install it on the Kindle, and verify local/remote main parity.
- Status: PR #5 squash-merged as `7975a0d`; v0.2.1 published from that revision with the verified plugin ZIP attached. Plugin files installed on the Kindle running KOReader v2026.07.2. Only this release handoff differs from the tagged source.
- Release scope: frontlight on/off synchronization from issue #6 and removal of three forced help-text line breaks from PR #5. Existing settings preserved.
- Verification: all 33 regression tests pass against the local KOReader source snapshot; local Lua syntax and whitespace checks pass. Uploaded ZIP downloaded and verified byte-for-byte against the source archive. Both installed modules match the release SHA-256 hashes and pass native Kindle Lua syntax checks.
- Previous device acceptance: issue #6 passed 18 checks inside the running KOReader session, including native hardware reads and the real toggle/notification path. The help-text change was not newly rendered during this release.
- Backup: previous installed modules retained in `/mnt/us/koreader/data/plugin-backups/kindleautobrightness-before-v0.2.1-20261015T080801Z/`. Existing older backup preserved.
- Activation: KOReader was already running during file replacement; restart KOReader once to load the new help strings. No forced termination, settings edits, or temporary HTTP inspector were used.
- Next: user restarts KOReader to activate the installed update; no further release or file-transfer work remains.
