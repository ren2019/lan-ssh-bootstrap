# LAN SSH Bootstrap

**Prepare SSH maintenance access for older Windows PCs on your local network.**

[简体中文](README.md) · **English**

LAN SSH Bootstrap helps configure SSH on older Windows PCs on a local network, making it easier to troubleshoot issues, inspect logs, and maintain the system from a terminal. A web guide brings file preparation, service configuration, public-key authorization, firewall rules, and an actual login check into one workflow.

## Currently supported setup

- **macOS → Windows:** run the tool on a Mac to configure and verify SSH public-key access to a Windows PC on the same trusted local network.
- **Windows → Windows:** initiating setup from another Windows PC is not yet supported.

On the initiating computer, choose a network interface and an SSH key. The Windows operator follows the Chinese or English web guide to open administrator PowerShell, review the proposed changes, and approve them. The tool then performs a real SSH login, checks the account identity, and prints a command for future connections.

Your private key stays on the initiating computer. An existing SSH installation is reused when the tool can inspect it reliably. The original configuration is backed up, with a recovery command provided before changes are applied.

> This is a `0.1.0-dev` development preview. Reusing an existing SSH installation, configuring public-key access, verifying login, and restoring settings have been tested on Windows 11. Fresh installation, standard-user isolation, and persistence after reboot still need real-device testing. Start with a recoverable test machine.

## What it helps with

- **Prepare files in one place:** the Mac downloads and caches a pinned official installer. Windows only needs access to the Mac during setup.
- **Guide the Windows operator:** the page includes Chinese and English instructions, language-specific screenshots, command copying, and session status.
- **Configure access:** authorize an existing local account, set sshd to start automatically, and add a firewall rule with a limited source address range.
- **Verify that it works:** compare host fingerprints on both machines, then perform a real public-key login and check the account SID.
- **Keep a recovery path:** back up the configuration, record changes, and check for subsequent edits before restoring settings.

## Example scenarios

### Troubleshoot an older PC for family or friends

Someone brings you a Windows PC that needs its processes, logs, or services checked. Connect it and your Mac to the same trusted local network, prepare SSH access, and continue troubleshooting from your familiar terminal.

### Prepare a Windows PC for occasional maintenance

A home or office Windows PC needs attention from time to time. Configure public-key access and verify the connection once, then use the generated SSH command whenever the machines are reachable over the network.

### Help another person complete the setup

You operate the Mac while someone else operates Windows. Share the temporary page address so they can follow screenshots in their language, open PowerShell, copy the command, and review the plan. This reduces the back-and-forth of describing menus and dictating long commands.

### Let the Mac handle the download

Windows may have slow access to external download sites while local networking works well. The Mac can fetch and cache the official installer and serve it locally. Windows does not need to reach the external download source; the Mac still needs internet access for the initial download, or a previously obtained copy of the pinned installer.

Troubleshooting, software removal, and system optimization remain under your control after SSH is ready. SSH provides terminal access; desktop interaction requires another method. Future connections also require network reachability. The tool does not provide remote-network connectivity or NAT traversal.

## Requirements

| Mac | Windows |
|---|---|
| macOS with the built-in `ssh` and `ssh-keygen` | Target: Windows 10 1809 or later, or Windows 11, x64 |
| An existing SSH key pair; the tool provides creation instructions if none is found | An administrator authorized to approve changes |
| A trusted local network that can reach Windows | A browser and 64-bit Windows PowerShell 5.1 |
| Internet access for the initial installer download | Access to the Mac during setup |

Domain accounts, Windows ARM, and 32-bit Windows are not supported. The target version range is not a claim that every version has been tested.

## Get started

Build from source with Go 1.24 or later:

```sh
git clone https://github.com/ren2019/lan-ssh-bootstrap.git
cd lan-ssh-bootstrap
sh scripts/build.sh
```

On an Apple Silicon Mac:

```sh
./dist/lan-ssh-bootstrap-darwin-arm64
```

On an Intel Mac:

```sh
./dist/lan-ssh-bootstrap-darwin-amd64
```

The built executable runs without an additional Go, Python, or Node runtime. The Intel build has only been cross-compiled, not tested on an Intel Mac.

### 1. Prepare the session on the Mac

Choose the network interface that can reach Windows and the SSH key you want to use, then confirm.

The tool downloads and caches a pinned official OpenSSH installer, checks its SHA256 on every use, and prints a temporary local address. Share that address with the Windows operator.

The private key remains on the Mac; only the public key is sent to Windows. If no key pair is found, the tool asks you to create one with `ssh-keygen -t ed25519` first.

### 2. Follow the guide on Windows

The web page offers Chinese and English instructions with matching screenshots:

1. Search for Windows PowerShell and run it as administrator.
2. Copy the generated command, paste it into PowerShell, and run it.
3. Review the account, installation status, firewall scope, and proposed changes. Enter `yes` to apply them, or exit.

The default account is the current desktop user. You can choose another enabled local account; the tool does not create accounts. The firewall scope defaults to the selected local subnet and can be narrowed to your Mac's address.

Windows does not need to find or download the installer from the internet.

### 3. Compare fingerprints and verify access

Windows displays its SSH host fingerprint. Compare it with the fingerprint shown on the Mac and confirm. The tool then logs in with the selected key and checks the account SID.

An existing inspectable SSH installation is reused, preserving its authentication policy. The fresh-install workflow is designed to disable password and keyboard-interactive authentication after a successful public-key login, then verify again. That fresh-install workflow has not completed real-device acceptance.

On success, the Mac prints a connection command. The web page remains available for 15 seconds, then the temporary download service closes. The configured SSH service keeps running for future maintenance. Use the recovery script to undo this session's configuration when it is no longer needed.

Press `Ctrl+C` to end the Mac session. If Windows times out or cannot report back, it attempts recovery. If recovery cannot proceed safely, it leaves instructions for manual review.

## Changes you can review

Before applying changes, the tool shows a plan that includes:

- Configuring public-key access for an existing account while preserving existing key sources.
- Starting sshd and setting automatic startup. Applying configuration may restart sshd and disconnect existing SSH sessions.
- Adding a firewall rule restricted to the selected source addresses.
- Keeping a backup of the original configuration and a recovery record.

The new key source is scoped to the selected account. The key is not added to the shared administrators key file. Existing firewall allow rules remain in place, so adding a local-network rule does not narrow access granted by other rules.

Custom sshd startup arguments, complex key paths, and other configurations that cannot be handled reliably cause the tool to stop and request manual configuration. It does not automatically replace or upgrade an existing SSH installation, or reboot the PC.

## Restore settings

After Windows approves the changes, backups and the recovery script are stored in:

```text
%ProgramData%\lan-ssh-bootstrap\sessions\<attempt>\
```

The console prints the corresponding recovery command. Run it in administrator PowerShell:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "<session-directory>\restore.ps1"
```

Before restoring, the script checks whether the configuration, public-key file, firewall rules, or service state have changed since setup. It stops on conflicts to avoid overwriting later work.

Recovery removes the public-key file and rules created by this session and restores the previous configuration and service state. A newly installed package and generated host keys are retained; fresh-install recovery still needs real-device testing. If the installer is still running or service ownership is uncertain, the temporary port-blocking rule may be retained with instructions for manual review.

## Network and trust boundary

Use this tool on a home or office network you trust.

The temporary service uses HTTP. Random session paths, source-subnet checks, and fixed routes help limit accidental access, but do not provide transport encryption or end-to-end authentication. An installer hash does not establish the trustworthiness of a script fetched over HTTP. Do not expose the service to the internet or use it on untrusted networks such as hotel or public Wi-Fi.

Fresh installation uses the pinned [Win32-OpenSSH 10.4.0.0p1-Preview](https://github.com/PowerShell/Win32-OpenSSH/releases/tag/10.4.0.0p1-Preview). Upstream labels it Preview / non-production ready. Before installation, Windows also requires a matching SHA256 and a valid Microsoft Corporation Authenticode signature.

## Verification status

| Path | Status |
|---|---|
| Apple Silicon Mac build, download, cache, startup, and exit | Tested |
| Chinese/English page switching, matching screenshots, and copying over HTTP in a Mac browser | Tested |
| Existing-install configuration and real public-key login on Windows 11 x64 | Tested, including account SID verification |
| Cancellation before changes, recovery after verification abort, and explicit recovery after success | Tested; original configuration bytes and service state restored |
| Rejection of the test key after revoking temporary access | Tested |
| Pinned MSI hash and Microsoft signature | Tested |
| Generating the same configuration again | Byte-identical; a second complete execution is pending |
| Fresh installation, standard-user isolation, and persistence after reboot | Pending real-device testing |
| Windows 10 versions, Intel Mac, and human-operated Windows browser flow | Pending real-device testing |

See [docs/VALIDATION.md](docs/VALIDATION.md) for the scope and methods.

## Options

```sh
# Use an existing key and a specific service port
./dist/lan-ssh-bootstrap-darwin-arm64 -key ~/.ssh/id_ed25519 -port 8765

# Use a previously obtained pinned installer; the embedded SHA256 is still checked
./dist/lan-ssh-bootstrap-darwin-arm64 -package /path/to/OpenSSH-Win64-v10.4.0.0.msi
```

`-bind` selects a private IPv4 address on an enabled local interface; otherwise the tool asks you to choose. Add `?lang=zh` or `?lang=en` to select the page language, which otherwise follows the browser language. Mac terminal prompts are currently primarily in Chinese.

## Development checks

```sh
go test -race ./...
go vet ./...
pwsh -NoProfile -NonInteractive -File scripts/check-powershell.ps1
node --check assets/app.js
```

The PowerShell checks use pure configuration logic and mocked recovery scenarios without changing real Windows settings. PowerShell and Node are only needed for development checks.

## License

Code is licensed under [MIT](LICENSE). Third-party screenshot sources and licenses are listed separately in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
