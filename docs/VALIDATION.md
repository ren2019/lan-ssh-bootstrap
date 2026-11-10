# Development validation — 2026-11-10

This is a development implementation, not an accepted Windows installer release.

| Check | Evidence / limit |
|---|---|
| Go state, transport, integrity and HTTP boundary checks | `go test -race ./...` passed on Apple Silicon macOS |
| Go static checks | `go vet ./...` passed |
| Vulnerability scan | govulncheck 1.9.0: no vulnerabilities found; database updated 2026-11-05 |
| PowerShell parsing, pure configuration and mocked recovery checks | Local PowerShell 7.6.1 passed; mocked recovery restores approved installation-time rules and refuses concurrent rule changes; no Windows settings changed |
| Windows PowerShell 5.1 | Final scripts passed UTF-8 parsing, pure configuration and mocked recovery on Windows 11 x64 build 26300 / PS 5.1.26100.9711 |
| Vendor download | Official pinned MSI downloaded; SHA256 `788d8643464a01eb63640a2fd746f9ed23d106b5a901a35f88dc8cd40e446ac9` matched |
| Vendor Authenticode gate | Pinned MSI downloaded over LAN on Windows; exact SHA256 matched; Authenticode Valid, Microsoft Corporation. Fresh-install branch not run |
| Mac build | Darwin ARM64/AMD64 build with Go 1.27.3; ARM64 version, fixed-package download, cache reuse, start and Ctrl+C stop smoke checks on macOS 27.2 |
| Accepted UI | B checklist with Chinese/English text and native language-specific screenshots; accepted by user |
| Final web UI | Reimplemented for real session status, without simulator controls; native Safari confirmed Chinese/English screenshots and one-click copy on an actual private-IPv4 HTTP address. Language switch updates the command and clears stale copy feedback |
| Existing-install integration | Passed on Windows 11 x64 build 26300: cancel before write; configure account key + single-Mac firewall rule; two real public-key SID checks; abort recovery and successful-session recovery; original config bytes and service state restored; test key/rule removed; revoked test key rejected. Repeated configuration generation was byte-identical; a second full completed setup was not run |
| Fresh install / standard-user isolation | Not run; existing administrator account tested only |
| Post-reboot SSH / Windows 10 / other Windows 11 builds / SFTP | Not verified |

## Required real-device acceptance

Use a recoverable, idle Windows test machine and obtain local approval of the displayed changes. Check fresh install, existing-install reuse, account key scope, administrator/standard-user ACLs, effective firewall rules, public-key identity, fresh-install password disablement, cancellation/recovery, repeat execution and reboot persistence. Do not use an active machine as an unattended installation test.

## Source preview publication

The public repository contains development source, not a stable installer release. No fresh-install or cross-version compatibility claim is made. Temporary integration-test configuration changes were restored and verified. Private logs, device identities, tracker configuration and prototype history are excluded from the public source history.

The Chinese guide image is a project-captured Windows 11 search window, replacing the restricted prototype image. Screenshot replacement changes only the guide image and its attribution; installer behaviour is unchanged. The previous browser checks used the prototype image, so the replacement is additionally checked for local asset resolution and visually reviewed.

## Real-device findings

Fixed quoted UserKnownHostsFile handling for macOS configuration paths containing spaces; both actual SSH verification rounds then passed. Fixed the developer PowerShell checker to decode UTF-8 explicitly and emit a BOM for its temporary executable script on PS5.1.

Testing used a temporary SYSTEM scheduled task to keep the Windows workflow independent of sshd restarts; the chosen existing account, scope and confirmations were supplied by the authorized test harness. This validates the script and transport but not a human-operated Windows browser/console flow. The task, temporary download/scripts, test key and rule were removed after collecting private evidence. Recovery receipts remain for review. No reboot or SSH package replacement was performed.
