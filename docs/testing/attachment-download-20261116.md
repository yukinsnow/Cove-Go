# Attachment download investigation — 2026-11-16

- Report: installed iOS client displays delivery text but no attachment tile.
- Gateway `chat.history` was checked through the Gateway API (not raw transcript files). The delivery-mirror row includes a nested `attachment` block, managed artifact ID, filename, MIME type and 28,595,368-byte size.
- Current source already renders that schema. Baseline received-file tests: 9 passed. Missing-card root cause is not reproduced; installed version/build requested from user. Do not claim this is fixed on-device.
- UX changes: give received/selected file tiles an explicit surface; tapping a received file starts its download on the native detail page, without a second Load tap. Retry and Save to Files / Share remain available. No auto-install or extraction.
- Final focused tests: 14 passed across received_file_test.dart, received_file_ui_test.dart and attachments_test.dart. UI regression checks one download admission on card tap, no duplicate on rebuild, and error completion.
- Command: DSH_TEST_FONT_DIR=/home/ubuntu/.cache/cove-test-fonts /home/ubuntu/tools/flutter/bin/flutter test --no-pub test/openclaw/received_file_test.dart test/openclaw/received_file_ui_test.dart test/openclaw/attachments_test.dart --reporter expanded
- Targeted flutter analyze: no issues; dart format and git diff --check passed.
- Test harness needs existing CJK font directory and runAsync for real temporary-directory I/O. Earlier harness failures were corrected, not application failures.
- Temporary authenticated download ticket generated via artifacts.download for existing 0.1.25(26) IPA. Public HTTPS full download verified: 200, 28,595,368 bytes, SHA256 matches verified archive. Ticket is private and intentionally omitted from this document. Browser-like user agent needed for edge access; urllib default initially received 403.
- Changes not committed, pushed or packaged; no iPhone validation. Existing 0.1.25 IPA does not include these UX edits.
