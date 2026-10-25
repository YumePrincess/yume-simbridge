import { Buffer } from "node:buffer";
import { DkimVerifier } from "mailauth/lib/dkim/dkim-verifier";
import { writeToStream } from "mailauth/lib/tools";

class WorkerDKIMVerifier extends DkimVerifier {
  override async verifySignature(
    header: Parameters<DkimVerifier["verifySignature"]>[0],
    fallback = false,
  ) {
    // workerd's node:crypto accepts the digest name "sha256", not Node's
    // "rsa-sha256" alias. Upstream has already validated the original a= tag;
    // canonicalized signed bytes and the parsed signature remain unchanged.
    const original = header.algorithm;
    if (header.signAlgo === "rsa" && header.hashAlgo === "sha256")
      header.algorithm = "sha256";
    try {
      return await super.verifySignature(header, fallback);
    } finally {
      header.algorithm = original;
    }
  }
}

export async function dnsTXT(name: string, rr: string): Promise<string[][]> {
  if (rr !== "TXT") throw Error("Unsupported mail DNS query");
  const url = new URL("https://cloudflare-dns.com/dns-query");
  url.searchParams.set("name", name);
  url.searchParams.set("type", "TXT");
  const res = await fetch(url, {
    headers: { Accept: "application/dns-json" },
    redirect: "manual",
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) throw Error("Mail DNS lookup failed");
  const data = (await res.json()) as {
    Status: number;
    Answer?: { type: number; data: string }[];
  };
  if (data.Status !== 0) throw Error("Mail DNS lookup failed");
  return (data.Answer || [])
    .filter((r) => r.type === 16)
    .map((r) => {
      const chunks = r.data.match(/"(?:\\.|[^"\\])*"/g);
      if (!chunks) throw Error("Invalid mail DNS record");
      return chunks.map((v) => JSON.parse(v) as string);
    });
}

// Email Routing does not guarantee an Authentication-Results header to Workers.
// Verify the original signed bytes instead of accepting sender-supplied verdicts.
export async function verifySenderDKIM(
  raw: Uint8Array,
  sender: string,
  resolver = dnsTXT,
): Promise<string> {
  const domain = sender.toLowerCase().split("@")[1];
  let queries = 0;
  const verifier = new WorkerDKIMVerifier({
    sender,
    strict: true,
    minBitLength: 1024,
    resolver: async (name, rr) => {
      if (
        ++queries > 4 ||
        !name.toLowerCase().endsWith("._domainkey." + domain) ||
        !/^[a-z0-9_.-]+$/i.test(name)
      )
        throw Error("Unaligned mail signature");
      return resolver(name, rr);
    },
  });
  await writeToStream(verifier, Buffer.from(raw));
  for (const signature of verifier.results) {
    const fields = (signature.signingHeaders?.keys || "")
      .toLowerCase()
      .split(":")
      .map((s) => s.trim());
    if (
      signature.status.result === "pass" &&
      signature.signingDomain?.toLowerCase() === domain &&
      !signature.canonBodyLengthLimited &&
      signature.signatureTimeValid !== false &&
      ["from", "to", "subject", "content-type"].every((h) =>
        fields.includes(h),
      ) &&
      signature.id
    )
      return signature.id;
  }
  throw Error(
    "Valid sender DKIM signature covering From, To, Subject and body required",
  );
}
