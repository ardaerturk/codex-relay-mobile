# Relay for Codex

A private mobile companion for an existing Codex desktop session. Open a task from your phone, follow its progress, and send a prompt to the same task running on your host machine.

The main client is an installable Home Screen web app. Native macOS and iOS SwiftUI client sources are also included. Models, provider credentials, repositories and tools remain on the host. Relay does not call a model from your phone.

**Status: early, experimental desktop integration.** This is an independent project, not an official OpenAI client or a complete Codex replica. The bridge uses internal desktop IPC; it is not a supported public Codex API. Review the compatibility and verification notes before relying on it.

## How it works

```text
Phone / browser
    │ private HTTPS + WebSocket over Tailscale
    ▼
Tailscale Serve
    │ 127.0.0.1:8787
    ▼
Python bridge
    │ existing desktop IPC socket
    ▼
Codex desktop on your host → configured model provider
```

The bridge follows the owner of an existing desktop task. It does not start a second Codex engine against that task or synchronize live Codex state between machines. Azure OpenAI credentials can stay entirely on the host.

## Features

- Existing task list, search, pagination and pinned-task indicators.
- Conversation history and streaming updates from the desktop session.
- Markdown, code, expandable command/tool output and file-change review.
- Text prompts, active-turn follow-ups and a stop control.
- Supported command/file approval requests and structured user-input questions.
- Delivery IDs and a persistent journal to avoid automatically replaying uncertain actions.
- Dark, light and system appearance; responsive task drawer and mobile composer.
- Home Screen installation without TestFlight or weekly app signing.

## Requirements

- An already configured and running Codex **desktop** installation on a Linux host. The CLI alone is not sufficient for this adapter.
- Tailscale on the host and phone, with appropriate access within your tailnet.
- Python 3.11+ and Node.js 22+ with npm.
- HTTPS through Tailscale Serve.
- Access to the desktop user's `~/.codex/ipc/ipc.sock` and `~/.codex/state_5.sqlite`.

The current adapter was inspected against a desktop installation whose bundled engine reports `0.153.4`, using conversation-stream IPC version 11. Other versions are not certified. An unknown protocol version or a revision gap disables writes instead of guessing.

## Install on the host

These examples use a checkout at `~/codex-relay-mobile`. Change the service paths if you choose another directory. Run the bridge as the same user who runs Codex desktop.

```sh
git clone https://github.com/ardaerturk/codex-relay-mobile.git ~/codex-relay-mobile
cd ~/codex-relay-mobile
python3 -m venv .venv
.venv/bin/pip install -r Bridge/requirements.txt
npm ci --prefix Web
npm run build --prefix Web
python3 Scripts/create_pairing_token.py
```

The last command creates a random pairing credential at `~/.local/state/relay/pairing-token` with mode `0600`. It never prints or overwrites an existing credential. No real credentials are included in this repository.

Enable private HTTPS, then inspect the actual URL Tailscale assigns:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:8787
tailscale serve status
```

Create `~/.config/relay/bridge.env` with your actual URL. The value below is a placeholder, **not a hosted service**:

```ini
RELAY_ORIGIN=https://your-vm.your-tailnet.ts.net:8443
RELAY_HOST_LABEL=My Codex host
```

Use the exact HTTPS origin, including a nonstandard port. Do not put a path, username, password or query string in it. The bridge refuses to start without a valid HTTPS origin.

Install the user service:

```sh
mkdir -p ~/.config/systemd/user
cp Bridge/relay-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now relay-bridge.service
systemctl --user status relay-bridge.service
```

If the service must survive logout, configure user lingering according to your host's administration policy. Codex desktop must also remain running. This project does not start or reconfigure your desktop session.

## Pair your iPhone

1. Connect the iPhone to the same Tailscale network.
2. Open your private HTTPS address in Safari.
3. Enter the pairing credential. On a Mac with an existing SSH config alias for the host, run `Scripts/copy-pairing-code.sh your-ssh-host` to copy it to the clipboard. Otherwise read `~/.local/state/relay/pairing-token` directly on the host and transfer it through your usual secure method.
4. Choose **Share → Add to Home Screen**, enabling **Open as Web App** if shown.
5. Open Relay from the Home Screen. If iOS separates its browser storage, pair again there.

Sessions expire after 30 days; signing in again does not require reinstalling the app. Free Xcode Personal Team provisioning expires after seven days, while TestFlight requires Apple Developer Program membership. Neither requirement applies to this Home Screen web app. See Apple's [membership comparison](https://developer.apple.com/support/compare-memberships/) and [TestFlight documentation](https://developer.apple.com/testflight/).

## Limitations

- New task creation and model changes still happen in the desktop app.
- A task needs a live desktop owner. If Relay asks you to open a task on the host first, it cannot yet control that task alone.
- Attachments, voice, interactive terminals and app-wide settings are not implemented. Unsupported permission and elicitation requests must be handled on the host.
- iOS can suspend the web app in the background. Work continues on the host, and the client reconnects when opened. Push notifications are not implemented.
- Draft text stays in memory and may be lost if the browser discards the app.
- Internal desktop IPC can change after an update; maintenance may be required.

## Security boundaries

Tailscale provides private network transport. Relay additionally requires a high-entropy pairing credential. The Python process listens only on `127.0.0.1`; keep it behind private Tailscale Serve and do not expose it through Funnel or a public reverse proxy.

Browser sessions use HttpOnly, Secure, SameSite=Strict cookies. Cookie-authenticated writes and WebSocket upgrades require the configured exact origin. Native requests use a bearer credential. The bridge exposes a narrow operation allowlist, not an arbitrary shell or generic IPC endpoint.

Conversation data and authentication responses never enter the service-worker cache. Only app-shell assets are cached for offline loading. Session hashes and delivery records are stored in `~/.local/state/relay/delivery.sqlite`, with mode `0600`.

Signing out revokes the current browser session. To revoke all sessions, stop the service, clear the `sessions` table in that database, and restart it. Rotating the pairing file alone does **not** revoke existing browser sessions. A delivery marked uncertain is not automatically sent again; inspect the task before retrying.

## Configuration

| Variable | Purpose / default |
| --- | --- |
| `RELAY_ORIGIN` | Required exact private HTTPS origin |
| `RELAY_HOST_LABEL` | Host name returned by the health API; defaults to `Codex host` |
| `RELAY_CODEX_HOME` | Desktop state directory; defaults to `~/.codex` |
| `RELAY_STATE_DIR` | Relay session/delivery directory; defaults to `~/.local/state/relay` |
| `RELAY_TOKEN_FILE` | Pairing credential path; defaults to the state directory's `pairing-token` |
| `RELAY_WEB_DIR` | Compiled web assets; defaults to this checkout's `Web/dist` |
| `RELAY_PORT` | Loopback HTTP port; defaults to `8787` |

## Development and validation

```sh
.venv/bin/python Bridge/test_bridge.py
npm test --prefix Web
npm run build --prefix Web
```

The GitHub workflow runs these checks on Linux. A read-only live integration check is also available:

```sh
.venv/bin/python Bridge/smoke.py "$RELAY_ORIGIN" ~/.local/state/relay/pairing-token
```

That check reads real task history and a WebSocket snapshot. It does not send a model prompt or approve a tool.

Verification to date:

- Real private HTTPS, authentication, task list, desktop-owned history and WSS snapshots passed on the original Linux deployment.
- A read-only complete-history request and incremental reconciliation passed with the native URLSession client.
- Protocol tests cover duplicate delivery, uncertain outcomes, stale stops, active/idle routing, request validation, origin checks and session revocation.
- Browser QA checked mobile widths, task search, tool disclosures, test-send acknowledgment, appearance, sign-in persistence and logout with isolated fixtures.
- Actual iPhone Home Screen installation, software-keyboard behavior, and a live model send/stop/approval cycle still require end-to-end verification.

### Native Mac app

On a Mac with Xcode command-line tools, build and open the native app:

```sh
Scripts/build-macos.sh
open build/macos/Relay.app
```

This targets macOS 14+ and uses the Mac's login Keychain. The build is locally ad-hoc signed; an Apple developer membership is not required to build and run it locally. It is not a notarized distribution build.

The earlier Mac Catalyst preview returned `Keychain is unavailable (-34018)` because it lacked the entitlement required by the data-protection Keychain. Use this native Mac build for local use. Credentials remain in Keychain; there is no plaintext or in-memory-only fallback. iOS continues using its device-only data-protection Keychain.

Native Keychain save, update, read in a second process, and deletion are covered by `Tests/KeychainChecks.swift`. A local app connection also verified credential storage and real task-list retrieval from a private host.

### iOS client

Open `Relay.xcodeproj` in Xcode, choose your own bundle identifier and signing team, and enter your private bridge URL in the connection screen. The source targets iOS 18+. It stores pairing credentials in the device Keychain rather than iCloud.

An unsigned device build passed before icon-asset integration. The final asset-enabled build was blocked in the original development environment by an unavailable iOS simulator runtime. A signed installable or TestFlight build is not provided. The web app is the primary deployment route.

### Updating

Rebuild `Web/dist` and serve the new assets. Keep old hashed assets long enough for already-open clients to finish loading. Restart the bridge when its Python source changes; a web-client update does not require restarting Codex.

For logs and connection status:

```sh
journalctl --user -u relay-bridge.service -n 50
tailscale serve status
```
