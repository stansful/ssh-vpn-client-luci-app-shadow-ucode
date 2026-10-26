import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
export async function resolve(specifier, context, next) {
  if (specifier.endsWith(".js") && context.parentURL && (specifier.startsWith("./") || specifier.startsWith("../"))) {
    const url = new URL(specifier, context.parentURL);
    const ts = url.href.replace(/\.js$/, ".ts");
    if (!existsSync(fileURLToPath(url)) && existsSync(fileURLToPath(ts))) return next(ts, context);
  }
  return next(specifier, context);
}
