#!/usr/bin/env node
// Lab 9: copy the meetings from the API on AWS into Cloud Firestore, so the
// Firebase build shows the same data. Uses only Node's built-in fetch.
//
//   node scripts/seed-firestore.mjs https://api.yulia-spry.xyz spry-yulia-2026
//
// Writes go through firestore.rules like any browser would (no admin key):
// deploy the rules first (make deploy-firebase does).
const [apiUrl = process.env.BACKEND_URL, project = "spry-yulia-2026"] = process.argv.slice(2);
if (!apiUrl) {
  console.error("usage: node scripts/seed-firestore.mjs <api-url> [project-id]");
  process.exit(1);
}

const base = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents`;

const existing = await (await fetch(`${base}/meetings?pageSize=300`)).json();
if (existing.error) {
  console.error(`Firestore: ${existing.error.message}`);
  process.exit(1);
}
const already = new Set(
  (existing.documents ?? []).map((d) => `${d.fields?.title?.stringValue}|${d.fields?.starts_at?.timestampValue}`),
);

const res = await fetch(`${apiUrl.replace(/\/$/, "")}/api/v1/meetings?limit=200`);
if (!res.ok) {
  console.error(`API: ${res.status} ${await res.text()}`);
  process.exit(1);
}
const { meetings } = await res.json();

let copied = 0;
for (const m of meetings) {
  const startsAt = new Date(m.starts_at).toISOString();
  if ([...already].some((k) => k.startsWith(`${m.title}|`) && new Date(k.split("|")[1]).toISOString() === startsAt)) {
    continue;
  }
  const fields = {
    title: { stringValue: m.title },
    starts_at: { timestampValue: startsAt },
    ends_at: { timestampValue: new Date(m.ends_at).toISOString() },
    attendee_count: { integerValue: String(m.attendee_count) },
    created_at: { timestampValue: new Date(m.created_at).toISOString() },
  };
  if (m.agenda) {
    fields.agenda_json = {
      stringValue: JSON.stringify({ items: m.agenda.items, action_items: m.agenda.action_items }),
    };
  }
  const put = await fetch(`${base}/meetings`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  if (!put.ok) {
    console.error(`could not copy "${m.title}": ${(await put.json()).error?.message}`);
    process.exit(1);
  }
  copied += 1;
}
console.log(`${meetings.length} meetings on AWS, ${copied} copied to Firestore (${project}).`);
