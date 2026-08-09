import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const adapterRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

// Windows cannot exec a .sh file directly: spawn() on one fails with EFTYPE
// (verified), because the shebang is a POSIX kernel feature with no Windows
// equivalent. Everywhere else the script's own shebang and exec bit are what
// make the direct spawn work, so the interpreter is added ONLY on win32 and
// the POSIX invocation stays byte-identical.
//
// Git Bash is located from the well-known install layout rather than PATH:
// this adapter runs inside OpenCode, whose PATH is not guaranteed to carry a
// POSIX shell even when one is installed. An explicit "bash" is the last
// resort so a machine with bash on PATH still works.
function shellInvocation(script) {
  if (process.platform !== "win32") {
    return { command: script, args: [] };
  }
  const candidates = [
    process.env.FM_BASH,
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
    "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
  ].filter(Boolean);
  const bash = candidates.find((candidate) => existsSync(candidate)) ?? "bash";
  return { command: bash, args: [script] };
}

// Cross-language adapter only. bin/fm-operational-input.sh owns the protocol,
// accepted kinds, marker bytes, and serialization grammar.
export function encodeFirstmateOperationalInput(root, kind, content) {
  return new Promise((resolveResult, reject) => {
    const requested = `${root}/bin/fm-operational-input.sh`;
    const script = existsSync(requested)
      ? requested
      : `${adapterRoot}/bin/fm-operational-input.sh`;
    const { command, args } = shellInvocation(script);
    const child = spawn(command, [...args, "encode", kind], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0 && stdout) {
        resolveResult(stdout);
        return;
      }
      reject(new Error(stderr.trim() || `operational-input encoder exited ${code ?? "unknown"}`));
    });
    child.stdin.end(content);
  });
}
