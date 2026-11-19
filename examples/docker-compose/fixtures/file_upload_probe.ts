// Check upload destinations across the single-shot/streaming boundary in a live VM.
import { strict as assert } from "node:assert";
import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { createConnection } from "node:net";
import { join } from "node:path";
import { parseArgs } from "node:util";

const { values, positionals } = parseArgs({
  args: Deno.args,
  allowPositionals: true,
  options: { image: { type: "string" }, "guest-directory": { type: "string", multiple: true } },
});
const [runtime, machine, stateDirectory] = positionals;
assert(runtime && machine && stateDirectory && values.image, "runtime machine state_directory --image IMAGE required");
const directories = values["guest-directory"] ?? ["/tmp", "/workspace", "/opt"];
const token = crypto.randomUUID();
const decoder = new TextDecoder();
async function run(...args: string[]) {
  const result = await new Deno.Command(runtime, {
    args: ["machine", ...args], stdout: "piped", stderr: "piped", signal: AbortSignal.timeout(90_000),
  }).output();
  assert(result.success, decoder.decode(result.stderr));
  return decoder.decode(result.stdout).trim();
}
const agentSocket = join(await run("data-dir", "--name", machine), "agent.sock");
async function overlayRequest(method: "prepare_overlay" | "cleanup_overlay") {
  const encoded = Buffer.from(JSON.stringify({
    method, workload_id: `persistent-upload-probe-${token}`,
    ...(method === "prepare_overlay" ? { image: values.image } : {}),
  }));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(encoded.length);
  const connection = createConnection(agentSocket);
  connection.setTimeout(90_000, () => connection.destroy(new Error("Agent request timed out")));
  connection.write(Buffer.concat([header, encoded]));
  let response = Buffer.alloc(0);
  try {
    for await (const chunk of connection) {
      response = Buffer.concat([response, chunk]);
      if (response.length >= 4 && response.length >= 4 + response.readUInt32BE()) {
        const reply = JSON.parse(response.subarray(4, 4 + response.readUInt32BE()).toString());
        assert.equal(reply.status, "ok", `${method} failed: ${JSON.stringify(reply)}`);
        return;
      }
    }
    throw new Error("Agent closed an incomplete response");
  } finally {
    connection.destroy();
  }
}

// Keep a separate overlay prepared so resolving a guest destination yields
// an internal storage path distinct from the running workload's root. This
// catches the false-success regression that a simple round trip can miss.
await overlayRequest("prepare_overlay");
await Deno.mkdir(stateDirectory, { recursive: true });
const directory = await Deno.makeTempDir({ prefix: "verify-uploads-", dir: stateDirectory });
try {
  const source = join(directory, "source.bin");
  const downloaded = join(directory, "downloaded.bin");
  for (const size of [1 << 20, (1 << 20) + 1, (2 << 20) + 37]) {
    const payload = Uint8Array.from({ length: size }, (_, index) => index % 256);
    await Deno.writeFile(source, payload);
    const expected = createHash("sha256").update(payload).digest("hex");
    for (const destination of directories) {
      const guestPath = `${destination}/smolvm-upload-probe-${token}.bin`;
      try {
        await run("cp", "--mode", "600", "--uid", "65534", "--gid", "65534", source, `${machine}:${guestPath}`);
        // Inspect from the running workload, independently of the
        // file API: an upload/download pair can agree on a wrong path.
        const digest = await run("exec", "--name", machine, "--", "sha256sum", guestPath);
        assert.equal(digest.split(/\s+/)[0], expected, `Wrong contents at ${guestPath}`);
        const metadata = await run("exec", "--name", machine, "--", "stat", "-c", "%a %u %g", guestPath);
        assert.equal(metadata, "600 65534 65534", `Wrong permissions/ownership at ${guestPath}`);
        await run("cp", `${machine}:${guestPath}`, downloaded);
        assert.deepEqual(await Deno.readFile(downloaded), payload, `Download differs at ${guestPath}`);
        console.log(`  ok: ${size}-byte upload visible at ${destination}, metadata and download`);
      } finally {
        // Only this probe's unique file; never traverse directories.
        await run("exec", "--name", machine, "--", "rm", "-f", "--", guestPath);
      }
    }
  }
} finally {
  await overlayRequest("cleanup_overlay");
  await Deno.remove(directory, { recursive: true });
}
