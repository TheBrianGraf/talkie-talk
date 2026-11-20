// Portable installs can't self-update in place (no installer, and Windows won't
// let a running exe replace itself). When an update manifest names an NSIS
// setup.exe for this machine, the dialog links straight at that file.

/**
 * Pick the NSIS installer URL for the running target out of the update manifest.
 * Returns null when the manifest has no installer for this target, so the dialog
 * never opens a releases page on its own.
 *
 * @param rawJson `Update.rawJson`, the deserialized `latest.json` manifest
 * @param platformName value from `@tauri-apps/plugin-os` `platform()`
 * @param archName value from `@tauri-apps/plugin-os` `arch()` ("x86_64", "aarch64")
 */
export function resolvePortableInstallerUrl(
  rawJson: Record<string, unknown> | undefined,
  platformName: string,
  archName: string,
): string | null {
  // NSIS is a Windows-only bundle; nothing else has an installer to link to.
  if (platformName !== "windows") return null;

  const platforms = rawJson?.platforms;
  if (!platforms || typeof platforms !== "object") return null;

  const entry = (platforms as Record<string, unknown>)[
    `windows-${archName}-nsis`
  ];
  if (!entry || typeof entry !== "object") return null;

  const url = (entry as Record<string, unknown>).url;
  return typeof url === "string" ? url : null;
}
