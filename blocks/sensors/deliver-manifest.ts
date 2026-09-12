// deliver-manifest — blocking sensor for the deploy-verify stage.
// Spawned by the sensor runner as: bun <this>.ts --stage <id> --file-path <rel>
// once per workspace file matching `**/environments/production.json`.
// Verdict: last stdout line JSON { pass: boolean, ... } (exit 0 either way).
//
// PASS requires the manifest to parse and to carry every key the platform's
// environment view depends on, with a verified 200 and an https URL.

import { readFileSync } from "node:fs";

interface Verdict {
	pass: boolean;
	missing: string[];
	problems: string[];
	url?: string;
}

const REQUIRED = [
	"environment",
	"flavor",
	"status",
	"url",
	"commit",
	"pipeline_run",
	"deployed_at",
	"verified_http_status",
	"resources",
] as const;

const argFile = (() => {
	const i = process.argv.indexOf("--file-path");
	return i >= 0 ? process.argv[i + 1] : undefined;
})();

const verdict: Verdict = { pass: false, missing: [], problems: [] };

try {
	const raw = readFileSync(argFile ?? "environments/production.json", "utf8");
	const m = JSON.parse(raw);

	for (const key of REQUIRED) {
		if (!(key in m)) verdict.missing.push(key);
	}
	if (m.status !== "deployed") verdict.problems.push(`status is '${m.status}', expected 'deployed'`);
	if (typeof m.url !== "string" || !m.url.startsWith("https://"))
		verdict.problems.push("url must be an https:// URL");
	if (m.verified_http_status !== 200)
		verdict.problems.push(`verified_http_status is ${m.verified_http_status}, expected 200`);
	if (m.resources && (!m.resources.site_bucket || !m.resources.distribution_id))
		verdict.problems.push("resources must carry site_bucket and distribution_id");
	if (typeof m.commit !== "string" || m.commit.length < 7)
		verdict.problems.push("commit must be a git SHA");

	verdict.url = typeof m.url === "string" ? m.url : undefined;
	verdict.pass = verdict.missing.length === 0 && verdict.problems.length === 0;
} catch (e) {
	verdict.problems.push(`manifest unreadable: ${e instanceof Error ? e.message : String(e)}`);
}

console.log(JSON.stringify(verdict));
