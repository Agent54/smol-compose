import { strict as assert } from "node:assert";
import { createConnection } from "node:net";

const [path, expected] = Deno.args;
const client = createConnection(path);
client.setTimeout(10_000, () => client.destroy(new Error("Socket probe timed out")));
client.end("probe\n");
client.setEncoding("utf8");
let received = "";
for await (const chunk of client) received += chunk;
assert.equal(received.trim(), expected);
console.log(received.trim());
