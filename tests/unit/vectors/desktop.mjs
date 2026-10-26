// The desktop app's sources for the vector generators: DESKTOP_SRC is a checkout of
// https://github.com/stansful/ssh-vpn-client-electron (only read, never changed).
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

// desktopModule("src/core/proxy/") -> file URL of that directory in the desktop checkout
export function desktopModule(dir) {
  const root = process.env.DESKTOP_SRC;
  if (!root) {
    console.error("Set DESKTOP_SRC to a checkout of https://github.com/stansful/ssh-vpn-client-electron");
    process.exit(2);
  }
  const path = resolve(root, dir);
  if (!existsSync(path)) {
    console.error(`DESKTOP_SRC=${root}: ${dir} is missing (not a checkout of ssh-vpn-client-electron?)`);
    process.exit(2);
  }
  return pathToFileURL(path).href + "/";
}
