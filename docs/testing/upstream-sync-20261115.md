# Cove-Go remote chat synchronization — 2026-11-15

## Scope / 范围

Worktree: `/home/ubuntu/projects/openclaw-go-upstream-sync`, branch
`sync/upstream-20261114`, base `09a27a38`.
The original `openclaw` worktree remains unchanged. No commit, push, PR,
release or new IPA has been made in this continuation.

对照分支保留 Cove-Go 双后端入口、品牌与原模型图标；不整包合并上游。
同步 DSH 远程聊天的历史恢复、传输重连、附件引用、流式投影缓存、
长工具输出及图片浏览；SSH 接入压缩和连接已有 DSH 模式；远程包包含
设备配对协议。OpenClaw 复用共享渲染，并接入消息内多图浏览和长工具输出。

The DSH protocol features are not presented as Gateway capabilities.
OpenClaw image gallery loaders capture their original host/session so switching
chats cannot redirect an already open gallery to another host.

## Resume audit / 中断恢复核对

Existing logs, not repeated tests:

- `logs/remote-tests.log`: 499 passed, 4 skipped.
- `logs/client-tests3.log`: 732 passed, 31 skipped (live prerequisites absent).
- Previous App analysis failed with 16 compatibility errors; previous widget
  tests failed to load. These were not successful verification.

Continuation fixes:

- Remove unused voice-call icon aliases referring to glyphs not shipped in this
  app; do not add unrelated voice functionality.
- Adapt three chat test doubles to the optional `autoApprove` argument.
- Remove cloud-voice overrides from the imported chat harness: that feature is
  not part of this app, and its source file is absent.
- Restore the original model icon rather than accepting unrelated visual drift.
- Normalize the public pairing JSON fixture to LF (JSON values unchanged).
- Install the missing Noto Sans CJK Light test fixture outside the repository;
  run widget tests with `DSH_TEST_FONT_DIR=/home/ubuntu/.cache/cove-test-fonts`.

## Verification / 验证

- `flutter analyze` (`logs/sync-analyze5.log`): no issues.
- `dart analyze packages/dsh_client packages/dsh_remote`
  (`logs/sync-packages-analyze.log`): no issues.
- `python3 app/tool/l10n_merge.py --check`: 74 parts, 8086 keys, passed.
- `git diff HEAD --check`: passed.
- SSH compression and transport hardening: 36 passed (`logs/ssh-regression.log`).
- Widget regression: 60 remaining relevant test files running, selected from
  changed chat/remote tests plus all OpenClaw tests. Completed files are listed
  in `logs/sync-selected-tests.json` and are not repeated. The broader sweep
  was intentionally stopped after unrelated golden failures were isolated.
- Dock golden baseline check on unchanged `openclaw` (`09a27a38`):
  the same 14 golden failures reproduce, 1 geometry check passes
  (`../openclaw-go/logs/sync-baseline-dock.log`). Do not update baselines
  merely to hide these environment-dependent differences.

The first widget attempt lacked test fonts. The following run exposed the model
icon golden mismatch and then a Flutter stream shutdown error. Its zero exit
status is NOT evidence of passing tests. The next run uses `--concurrency=1`.

未进行 iPhone / Android 真机、真实 DSH / Gateway 端到端及 iOS 编译验证。
Desktop checks do not establish device or delivery success.

Baseline header and artifact checks also reproduce the same 4 and 10 golden
failures on unchanged `09a27a38`. All 28 failing golden test cases seen in the broad
sweep also fail on the unchanged branch (Dock pixel counts are not all
identical; do not infer pixel-equivalent rendering or a green golden suite); see original worktree
`logs/sync-baseline-{dock,header,artifact}.log`. No golden files were updated.

## Additional compatibility fixes / 补充修复

- `state/session_modes.dart` now watches the turns/log projection instead of
  streamed items. The new cache can retain items through a permission event;
  watching items alone missed permission updates.
- Expose the existing opt-in compact-history controller in the remote settings
  page and searchable setting index, without replacing Cove-Go's host groups.
- Adapt credit hit-area tests to Cove-Go's combined DSH/SSH card and footer.
- Adapt OpenClaw image tests to the new `ZoomableImage` implementation; keep
  checking preview/send/confirmation flows. Remove duplicate controller disposal
  from the new gallery test (the home widget owns it).
- Remaining-failure rerun plus setting-index checks: `logs/sync-repair.log`.

## Continuation results / 本轮结果

- `logs/sync-focused.log`: 60 relevant files, 564 passed, 4 skipped, 10 failed
  before compatibility fixes. These are not presented as a green batch.
- `logs/sync-repair.log`: all 10 prior failures resolved; 95 passed, 1 failed.
  The one new failure from the additional index check exposed an existing
  search-title mismatch: the SSH index used the upstream title rather than
  Cove-Go's DSH-specific title. The index now uses `ocAddDshSsh`.
- `logs/sync-analyze-final.log`: no issues after the compatibility fixes.
- Final narrow index rerun (`logs/sync-index-final.log`): 1 passed.
- Post-title-fix analysis (`logs/sync-analyze-final2.log`): no issues.
- Final `git diff HEAD --check`: passed; original worktree is clean.

No claim of a clean full-app/golden suite or physical-device validation.
The interrupted broad sweep is separate from the completed relevant-file batch.
