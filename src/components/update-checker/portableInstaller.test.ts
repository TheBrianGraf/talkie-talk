// Standalone assert check (no JS unit-test runner in this repo). Run with:
//   bun src/components/update-checker/portableInstaller.test.ts
import assert from "node:assert";
import { resolvePortableInstallerUrl } from "./portableInstaller";

const X64_SETUP = "https://example.com/releases/App_0.9.5_x64-setup.exe";
const ARM64_SETUP = "https://example.com/releases/App_0.9.5_arm64-setup.exe";

const manifest = {
  version: "0.9.5",
  platforms: {
    "windows-x86_64-nsis": { url: X64_SETUP, signature: "…" },
    "windows-x86_64-msi": {
      url: "https://example.com/releases/App_0.9.5_x64_en-US.msi",
    },
    "windows-aarch64-nsis": { url: ARM64_SETUP, signature: "…" },
    "darwin-aarch64": {
      url: "https://example.com/releases/App_aarch64.app.tar.gz",
    },
  },
};

// x64 Windows -> the x64 NSIS asset
assert.equal(
  resolvePortableInstallerUrl(manifest, "windows", "x86_64"),
  X64_SETUP,
);

// arm64 Windows -> the arm64 NSIS asset
assert.equal(
  resolvePortableInstallerUrl(manifest, "windows", "aarch64"),
  ARM64_SETUP,
);

// no manifest -> nothing to open
assert.equal(resolvePortableInstallerUrl(undefined, "windows", "x86_64"), null);

// no NSIS bundle for this arch -> nothing to open
assert.equal(resolvePortableInstallerUrl(manifest, "windows", "x86"), null);

// non-Windows portable install -> nothing to open, never a Windows .exe
assert.equal(resolvePortableInstallerUrl(manifest, "macos", "aarch64"), null);

// malformed manifest -> nothing to open
assert.equal(
  resolvePortableInstallerUrl({ platforms: "nope" }, "windows", "x86_64"),
  null,
);

console.log("portableInstaller: all assertions passed");
