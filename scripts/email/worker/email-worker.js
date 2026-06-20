// email-worker.js — Cloudflare Email Worker for pocket-homeserver email.
// Inbound: sender -> Cloudflare Email Routing (*@your-mail-domain) -> this Worker.
// Behavior (PURE BUFFER-AND-ACCEPT, see worker/README.md + docs/EMAIL.md):
//   read message.raw ONCE -> sha256 -> R2.put("pending/<sha>.eml", buf) -> return
//   (= SMTP 2xx accept). The phone NEVER receives a push; it PULLS R2 on wake
//   (mail-drain.py). The SMTP accept depends ONLY on Cloudflare-global R2 — never
//   on the phone being online.
//
// R2 is the system of record. setReject() is used ONLY for >25 MiB (already
// bounced upstream by CF) and unreadable streams. A transient R2 error throws ->
// CF retries the worker up to 3x in-session, then a permanent 5xx (the correct,
// unavoidable floor) — a phone outage can NEVER cause a bounce.

const MAX_BYTES = 25 * 1024 * 1024; // CF Email Routing already enforces 25 MiB upstream

export default {
  async email(message, env, ctx) {
    // 0. Defensive size guard (unreachable: CF rejects >25 MiB before the Worker runs).
    if (message.rawSize > MAX_BYTES) {
      message.setReject("Message exceeds 25 MiB limit");
      return;
    }

    // 1. Read the raw RFC822 stream ONCE into an ArrayBuffer.
    //    NOTE: do NOT pass message.raw (a length-unknown stream) to R2.put() —
    //    that errors "Provided readable stream must have a known length."
    //    <=25 MiB into the 128 MB Worker memory is safe. No MIME parsing here.
    let buf;
    try {
      buf = await new Response(message.raw).arrayBuffer();
    } catch (e) {
      // Truncated/corrupt source stream — retrying won't help. Permanent reject.
      message.setReject("Could not read message body");
      return;
    }

    // 2. Content hash = the canonical idempotency key (no trust in Message-ID).
    const digest = await crypto.subtle.digest("SHA-256", buf);
    const sha = [...new Uint8Array(digest)]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    const key = `pending/${sha}.eml`;

    // 3. DURABLE WRITE — inline, before accept. Put-if-absent (atomic create-only)
    //    collapses CF's up-to-3x in-session retries into one object. Defense-in-
    //    depth only: the phone-side ledger is the real dedupe authority, so this is
    //    safe even if onlyIf ever regressed.
    try {
      await env.MAILBUCKET.put(key, buf, {
        onlyIf: { etagDoesNotMatch: "*" },
        httpMetadata: { contentType: "message/rfc822" },
        customMetadata: {
          from: message.from || "",
          to: message.to || "",
          messageId: message.headers.get("Message-ID") || "",
          subject: message.headers.get("Subject") || "",
          sha256: sha,
          rawSize: String(message.rawSize),
          receivedMs: String(Date.now()),
        },
      });
      // returns null if the object already existed (retry / true dup) -> already durable -> accept.
    } catch (e) {
      // R2 transient error: no durable copy -> must NOT silently accept.
      // Throwing yields a 5xx that triggers CF's in-session retry (up to 3x);
      // only after exhausting retries does the sender bounce (the correct floor).
      throw new Error("Durable store unavailable, retry: " + e.message);
    }

    // 4. ACCEPT: returning normally (no forward, no setReject) = SMTP 2xx.
    //    Mail is durably in R2; the phone PULLS it on wake.

    // 5. OPTIONAL low-latency wake-ping (advanced; off by default in pure-pull).
    //    Fire-and-forget; if the phone is offline the ping is simply lost and the
    //    drain timer catches the mail. NEVER let this block or fail the accept.
    if (env.PING) {
      ctx.waitUntil(fetch(env.PING, { method: "POST" }).catch(() => {}));
    }
  },
};
