# Release gates (F-04 / F-07)

## Distinct states; no implicit deployment

- `build-release.sh` still refuses dirty measured source and builds from `git archive`. It now runs `release-quality-gates.sh` inside the committed export **before building**. Workflow files are included in that export because the Python CI regression tests inspect them.
- `finalize-release.sh <built-directory> <new-candidate-directory>` assembles a local read-only candidate. It reads AWS AMI/role/key metadata; it neither mutates AWS nor asserts deployment. It is not an offline metadata verifier. Local bundle verification is deliberately separate from live verification.
- `deploy-release.py` is the deployment entrypoint. Supply the reviewed cutover program as an argument array after `--`; there is no guessed default AWS mutation sequence. It verifies the candidate and independent approval, executes that program, then **executes** `verify-release.py --live`. Only the final successful gate emits `RELEASE_DEPLOYED_AND_LIVE_VERIFIED`.
- `--plan` performs only local candidate/approval validation. It never runs the cutover program or AWS/chain reads.
- A failed/interrupted cutover can have partial effects. A failed/inaccessible post-deployment gate emits `DEPLOYED_UNVERIFIED` and exits nonzero. There is no automatic rollback, grant creation, policy rewrite, or retry of deployment. Program/verifier output is captured, not blindly echoed; configuration may contain secrets. Use the read-only verifier separately for its bounded diagnostic messages.

Invocation shape (replace every placeholder with independently reviewed input):

```text
python3 offchain-rust/job-api/deploy/deploy-release.py /release/release-manifest.json \
  --security-baseline /approved/security-baseline.json \
  --baseline-sha256 EXTERNALLY_APPROVED_SHA256 \
  --rpc-url DIRECT_HTTPS_SEPOLIA_RPC \
  [--plan] -- /path/to/reviewed-cutover-program [its reviewed arguments]
```

Pass secrets to the cutover program through its safe environment/file mechanism, never command arguments or logs. The cutover program must wait for all AWS updates to settle, deploy this exact candidate, and not edit the trusted verifier/templates. Drain legacy F-01 workers and F-03 PutItem writers before enabling new writers. This wrapper cannot prevent a trusted cloud administrator from bypassing it manually.

## Independent approval

`--live` requires both a separate JSON baseline and its externally pinned SHA-256. Do not calculate a new digest from an unreviewed candidate during deployment and call it approval. Obtain the digest from the independent release review/approval channel. Run the verifier and templates from reviewed source.

The baseline contains **exactly**:

- `releaseId`: the approved final manifest's release ID; this binds every artifact hash and all non-secret environment values/secret commitments, including optional score composition. Rehashing altered policies or environment into a new manifest does not satisfy the old independent approval.
- `roleTrustPolicies`: an object keyed by the exact manifest instance/API/janitor role names, containing their complete approved AssumeRolePolicyDocument JSON. Include the score role name (last component of `scoreService.roleArn`) **if and only if** score is included. All runtime roles must be distinct. Missing or extra trust entries fail. The approved boundary inventory is empty: any runtime permissions boundary fails.
- `bucketEncryption`: the complete approved `ServerSideEncryptionConfiguration` object. The verifier additionally requires one AES256 or aws:kms encryption rule.

No baseline is generated automatically by build/finalization. A normal local consistency check without this baseline is **not** security approval or evidence of live state.

## Enforced authority and configuration

- Enumerate every inline/attached policy on instance/API/janitor and included score roles; require exactly the one manifest-named inline policy and no managed policies. Reject denied, missing or partial inventories and any permissions boundary. Compare full inline documents, KMS policy, approved trust documents, and exact instance-profile membership.
- `kms list-grants` must succeed and return an empty, complete inventory. Denial, missing fields, pagination tokens and nonempty grants are hard failures. The source KMS template includes only the explicitly approved `ReadOnlyGrantAudit` addition (`kms:ListGrants` for `arn:aws:iam::919437049909:user/hermes-tee-agent`). It adds no Decrypt/CreateGrant/administrative authority. A stale identity Allow alone is not evidence of a decrypt bypass through a restrictive KMS key policy; trusted cloud administration remains an explicit assumption.
- Compare finalized policies against the reviewed statement recipe, rendering literal selected AMI, instance type, subnet, security group, profile, PassRole ARN, bucket and log-function ARNs, plus PCRs/canonical selected key. Finalization renders those exact resources and adds the bucket policy artifact before hashing. Reject extra statements, wildcard selections and resources inconsistent with the selected tuple. The supported account/region remain fixed; subnet/group/bucket/profile/function selections need not equal stale template IDs. LaunchTaggedWorkers additionally requires the exact ec2:InstanceProfile ARN. Resolve that profile live to exactly the attested role.
- Job Lambda environment keys are closed: existing keys plus required `USD8_DEFI_INSURANCE`, `USD8_MAX_ACTIVE_WORKERS` (0–128), `USD8_MAX_STARTS_PER_HOUR` (1–1024). Explicit `USD8_MAX_ACTIVE_WORKERS=0` selects cost-only mode; the hard positive hourly starts/cost budget remains mandatory. A positive active-worker cap adds conservative capacity-proof requirements. The existing `USD8_TEE_MAX_AGE_SECONDS` override is optional when explicitly present in the approved manifest. Secret fields remain SHA-256 commitments. Compare the complete live key set and values internally. Bind the trusted module to the fixed Registry's live `defiInsurance`.
- `USD8_EC2_RECONCILIATION_BOUND_SECONDS` is optional: if exported during finalization, its exact value is captured in the public job environment and release ID, then compared exactly live. It must be a canonical positive decimal safe integer (1–9007199254740991); empty, zero, negative, fractional or unsafe values fail. It is an operator-reviewed assumption used by optional positive-cap reconciliation, not an inferred AWS guarantee. There is no default or auto-discovery. Leaving it unset preserves conservative no-empty-proof behavior for positive caps; cost-only mode (`USD8_MAX_ACTIVE_WORKERS=0`) requires no reconciliation-bound approval for rollout.
- Finalization requires explicit `DEFI_INSURANCE`, `USD8_MAX_ACTIVE_WORKERS`, `USD8_MAX_STARTS_PER_HOUR`, `LAMBDA_TIMEOUT_SECONDS`, and `JANITOR_TIMEOUT_SECONDS`. Existing arguments/environment remain required. No production key, budget or timeout default is chosen by this tooling. The two timeouts must be canonical integers 1–900 and become required integer `aws.lambdaTimeoutSeconds` / `aws.janitorTimeoutSeconds` fields. Missing or changed live `Configuration.Timeout` fails for either function.
- F-01 API policy grants GetObject/PutObject/ListBucket only for `control/*` in the existing bucket, plus read-only `ec2:DescribeInstances`. Control records support If-Match CAS, are not covered by the create-only bucket deny, and have **no lifecycle expiry**. Worker role permissions remain attested KMS only.
- Live bucket checks require the reviewed access policy/CORS, versioning Enabled, all four public-access blocks, BucketOwnerEnforced ACL disabling, approved encryption, and exact lifecycle rules: launch 1 day/noncurrent 1, terminal 30/noncurrent 7, requests 31/noncurrent 7. Extra rules—including expiry for settlements, control, secrets or releases—fail. Templates retain the original lifecycle unchanged.

## Optional score composition

Set all three inputs during finalization: `SCORE_PACKAGE` (the exact reviewed prebuilt Linux score ZIP), `SCORE_CONFIG_JSON`, and `SCORE_RUNTIME_POLICY_JSON` (the reviewed exact inline policy document). This adds `scoreLambda` and `scoreRuntimePolicy` to artifact/checksum inventories and `scoreService` to the release ID. The policy is copied byte-for-byte, not silently rewritten. It does not rebuild score, modify live IAM, or make score an enclave dependency. Leave all three unset to omit score; a partial composition fails.

The descriptor contains exactly:

```json
{
  "function": "the-reviewed-score-function-name",
  "roleArn": "arn:aws:iam::919437049909:role/USD8ScoreLambdaRole",
  "policyName": "the-reviewed-exact-inline-policy-name",
  "environment": {"USD8_SCORE_TABLE": "the-reviewed-exact-table-name"},
  "secretEnvironmentSha256": {},
  "functionUrlAuthType": "NONE",
  "timeoutSeconds": 25
}
```

The example shows shape, not a deployable configuration. Supply the complete non-secret environment and SHA-256 commitments for secret values. `USD8_SCORE_TABLE` must be an explicit non-secret table name; an ARN, wildcard or secret commitment cannot replace it. Put `USD8_SCORE_WORK_POLICY_JSON`, if used, in the non-secret map so its bounds can be inspected. Its five required fields/bounds match score runtime configuration; the gate enforces application deadline < hard timeout < lease, with lease at least ceiling(application timeout)+5 seconds. This recipe fixes the reviewed hard timeout at 25 seconds. Changing that recipe requires review.

The score authority gate binds the exact `policyName`, score role ARN, complete policy artifact and table environment. Its reviewed policy recipe is Version `2012-10-17` with exactly two Allow statements: `WriteDedicatedScoreLogs` grants only `logs:CreateLogStream` / `logs:PutLogEvents` on `arn:aws:logs:eu-central-1:919437049909:log-group:/aws/lambda/<function>:*`; `UseDedicatedScoreCheckpointTable` grants only `dynamodb:GetItem` / `dynamodb:UpdateItem` on `arn:aws:dynamodb:eu-central-1:919437049909:table/<USD8_SCORE_TABLE>`. Full document equality rejects missing UpdateItem, PutItem-only or broader action sets, extra statements, wrong/wildcard tables and extra conditions/principals. The score role must belong to the reviewed account and differ from other runtime roles. Live verification requires its exact named inline document, exhaustive exclusive inline/managed inventory, approved trust and no boundary, as for the other runtime roles. No live IAM widening is performed.

Live score checks bind ZIP hash, role, complete environment, hard timeout and Function URL authorization. This recipe expects a score Function URL; it does not verify API Gateway/alias routing, table TTL, old-version drainage, table-sharing consistency, concurrency or external HTTP throttles. Those remain F-03 cutover obligations. Omitting score composition means no claim about the deployed score package.

Preserve the independently read current timeouts through explicit approved inputs: parent live evidence reports `usd8-tee-job-api` Timeout **30**, Memory **512**, and `usd8-tee-janitor` Timeout **60**, Memory **256** (the old 29-second note was stale). To preserve those timeouts, explicitly supply `LAMBDA_TIMEOUT_SECONDS=30` and `JANITOR_TIMEOUT_SECONDS=60`; this is not a default or automatic live change. Reconfirm live state and review the sequential F-02 precheck budget at cutover. Memory is contextual evidence, not a newly bound field in this scoped timeout fix. The platform 900-second maximum remains the capacity-fencing platform bound; release-bound timeouts do not by themselves justify stronger EC2-absence assumptions.

## Linux and local tests

CI and the release build both invoke `release-quality-gates.sh` on Linux. Prerequisites include Rust 1.94.1 with fmt/clippy, cargo-audit, Python 3, Node/npm, AWS CLI and existing build tools. Its score-api graph is tested/clippied/audited independently with `--locked`; score-core has its own locked test/clippy/audit gates. Deploy Python and real-history helper tests run too. Existing root/job-api CI gates remain.

`with-dynamodb-tests.py` installs **dynalite@4.0.0** in a disposable directory outside the checkout, binds a dynamic loopback-only port, proves signed ListTables readiness with explicit dummy credentials, runs score tests with `--include-ignored`, and terminates/removes the emulator in cleanup. This exercises the actual SDK conditional-write races; plain default Cargo tests omit them.

Useful host test command (not a Linux release proof):

```sh
cd offchain-rust/score-api
PYTHONDONTWRITEBYTECODE=1 python3 ../job-api/deploy/with-dynamodb-tests.py -- \
  cargo +1.94.1 test --locked --all-targets --features lambda,sepolia -- --include-ignored
```

Audits deny warnings. Newly surfaced unmaintained/yanked packages must be resolved or receive explicitly reviewed narrow exceptions in their owning graph; never remove `--deny warnings` to get a green release. macOS host tests do not substitute for the Linux gate, real EIF/AMI validation, recipient-attested KMS/signing or required onchain/end-to-end release evidence.
