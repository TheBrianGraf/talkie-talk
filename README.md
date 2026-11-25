# Talkie-Talk

Private speech-to-text for your Mac. Hold a shortcut, talk, and the text appears
wherever your cursor is. Everything runs on your Mac with the on-device
[QVAC](https://github.com/tetherto/qvac) TranscribePsy model. Your voice is never
uploaded, and there is no cloud service, account, API key, or update server.

- Apple Silicon (M1 or later), macOS 13 or newer
- English, Dutch, French, German, Italian, Polish, Portuguese, Spanish
- One model, bundled inside the app, so it works offline from the first launch

Talkie-Talk is a fork of [Handy](https://github.com/cjpais/Handy) by CJ Pais (MIT).

## Install

One command, no clone and no account needed. It downloads the latest release and
installs it (to `/Applications`, or `~/Applications` if that is not writable):

```sh
curl -fsSL https://raw.githubusercontent.com/TheBrianGraf/talkie-talk/talkie-talk/scripts/install-mac.sh | bash
```

Or download the `.dmg` from [Releases](https://github.com/TheBrianGraf/talkie-talk/releases)
and drag Talkie-Talk into Applications. Because the app is not notarized, right-click it and
choose Open the first time.

## Build from source

```sh
git clone https://github.com/TheBrianGraf/talkie-talk && cd talkie-talk
./scripts/build-mac.sh      # builds the app and a .dmg (first build takes a while)
./scripts/install-mac.sh    # installs the build from this checkout
```

Build requirements: Rust (rustup), [Bun](https://bun.sh), CMake, Xcode Command Line Tools.

The first dictation asks for Microphone, Accessibility, and Input Monitoring access.

## Develop

```sh
bun install
CMAKE_POLICY_VERSION_MINIMUM=3.5 bun run tauri dev
```

The QVAC engine runs in its own helper process (`src-tauri/qvac-helper`, built by
`scripts/build-qvac-helper.sh`) so its ggml does not collide with the one linked into the app.

## License

MIT. See [LICENSE](LICENSE). Handy is Copyright (c) 2025 CJ Pais.
