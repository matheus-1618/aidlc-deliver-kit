// deliver-flavor-conformance — blocking sensor for the release-gate stage.
// Runs against infra/main.tf BEFORE any merge: code that violates the flavor's
// security invariants never reaches the release decision, let alone the cloud.
// Spawned as: bun <this>.ts --stage <id> --file-path <rel> ; verdict on stdout
// as JSON { pass, violations[] } (exit 0 either way).
//
// Textual checks, deliberately simple: the flavor templates are prescriptive
// enough that string/regex assertions are reliable, and simple means auditable.

import { readFileSync } from "node:fs";

const argFile = (() => {
	const i = process.argv.indexOf("--file-path");
	return i >= 0 ? process.argv[i + 1] : "infra/main.tf";
})();

const violations: string[] = [];
let tf = "";

try {
	tf = readFileSync(argFile, "utf8");
} catch (e) {
	console.log(JSON.stringify({ pass: false, violations: [`infra/main.tf unreadable: ${e}`] }));
	process.exit(0);
}

const must = (cond: boolean, msg: string) => {
	if (!cond) violations.push(msg);
};
const mustNot = (re: RegExp, msg: string) => {
	if (re.test(tf)) violations.push(msg);
};

// 1. Backend block empty — pipeline injects config; hardcoding breaks the contract.
must(/backend\s+"s3"\s*\{\s*\}/.test(tf), 'backend "s3" must be EMPTY ({} — the pipeline injects bucket/key/region)');

// 2. Project tag via default_tags — the teardown audit counts by this tag.
must(/default_tags\s*\{[\s\S]*?Project\s*=/.test(tf), "provider must set default_tags with a Project tag (teardown audit depends on it)");

// 3. deliver- prefix — the deploy role is scoped to it.
for (const m of tf.matchAll(/resource\s+"aws_s3_bucket"\s+"\w+"[\s\S]*?bucket\s*=\s*"([^"$]*)/g)) {
	must(m[1].startsWith("deliver-"), `bucket name must start with deliver- (found: ${m[1]}…)`);
}
for (const m of tf.matchAll(/function_name\s*=\s*"([^"$]*)/g)) {
	must(m[1].startsWith("deliver-"), `lambda function_name must start with deliver- (found: ${m[1]}…)`);
}

// 4. S3 fully blocked from the internet.
must(/aws_s3_bucket_public_access_block/.test(tf), "aws_s3_bucket_public_access_block resource is required");
for (const flag of ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]) {
	must(new RegExp(`${flag}\\s*=\\s*true`).test(tf), `${flag} must be true`);
}

// 5. CloudFront reads S3 only via OAC.
must(/aws_cloudfront_origin_access_control/.test(tf), "CloudFront must use an Origin Access Control for the S3 origin");

// 6. Nothing that opens the network beyond CloudFront.
mustNot(/resource\s+"aws_instance"/, "aws_instance is outside this flavor (no servers)");
mustNot(/resource\s+"aws_security_group"/, "security groups are outside this flavor (nothing to expose)");
mustNot(/associate_public_ip_address\s*=\s*true/, "public IPs are forbidden");
mustNot(/publicly_accessible\s*=\s*true/, "publicly_accessible resources are forbidden");
mustNot(/acl\s*=\s*"public/, "public S3 ACLs are forbidden");

// 7. Lambda (when present) stays minimal: only the AWS basic execution policy.
const attachedPolicies = [...tf.matchAll(/policy_arn\s*=\s*"([^"]+)"/g)].map((m) => m[1]);
for (const arn of attachedPolicies) {
	must(
		arn === "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
		`lambda exec role may only attach AWSLambdaBasicExecutionRole (found: ${arn})`,
	);
}
mustNot(/aws_iam_role_policy"\s/, "inline IAM policies on the exec role are outside this flavor");

// 8. Required outputs — the pipeline reads them by name.
for (const out of ["site_bucket", "distribution_id", "site_url"]) {
	must(new RegExp(`output\\s+"${out}"`).test(tf), `output "${out}" is required (pipeline contract)`);
}

console.log(JSON.stringify({ pass: violations.length === 0, violations }));
