# AKS HammerDB Deployment Plan (SQL Server Only)

## Objective

Deploy HammerDB into the existing AKS cluster so it can reliably:

1. Connect to the existing SQL Server pod/service in-cluster.
2. Initialize the TPROC-C schema.
3. Apply sustained load without the network instability observed from local-hosted runners.

This phase explicitly excludes Materialize and Locust.

## Current Assumptions (Confirmed)

1. SQL Server is already running in AKS.
2. SQL Server is reachable from a local machine today.
3. The main problem appears during ramp-up/high-operation load, likely due to path/network characteristics of running HammerDB outside AKS.
4. Existing HammerDB TCL scripts in this repo are environment-driven and reusable.

## Scope

In scope:

- HammerDB runtime in AKS.
- In-cluster SQL connectivity validation.
- Schema build/check and timed load run from HammerDB against SQL Server.
- Operational runbook and repeatable launch flow.

Out of scope (for now):

- Materialize setup.
- Locust workload.
- Full benchmark automation across multiple systems.

## Success Criteria

1. HammerDB pod/job resolves and connects to SQL Server Service DNS in AKS.
2. HammerDB build/check scripts complete successfully against SQL Server.
3. Timed run executes to completion without communication-link failures caused by external networking path.
4. Logs and result artifacts are captured for each run.

## Implementation Strategy

### Phase 1: Discover and Baseline AKS SQL Connectivity — **Status: ✅ Complete**

Goal: Confirm the in-cluster endpoint and connection behavior HammerDB must use.

Steps:

1. Identify SQL Server namespace, pod, and Service name/port.
2. Confirm Service type and DNS name for in-cluster clients.
3. Validate auth mode and credentials to be used by HammerDB.
4. Execute a short in-cluster connectivity probe from a temporary debug pod.
5. Record baseline command(s) and expected outputs.

Deliverables:

- Confirmed SQL endpoint details:
  - namespace: `sql-server`
  - service DNS: `mssql.sql-server.svc.cluster.local`
  - port: `1433`
  - database: `tpcc` (pre-existing; also present: `materialize_source`)
  - login user: `sa`
  - credential secret: `mssql-sa-password` (key: `MSSQL_SA_PASSWORD`) in namespace `sql-server`
  - SQL Server version: Microsoft SQL Server 2022 (RTM-CU25) 16.0.4255.1, Developer Edition on Linux (Ubuntu 22.04, X64)
  - Pod: `mssql-6467f6ccf9-8vc6r` on node `aks-sqlx64-49953808-vmss000000`
  - Node architecture: arm64
- Connectivity probe command documented (see below).

Connectivity Probe Commands (validated):

```bash
# TCP check (run from any pod in cluster)
nc -z -w5 mssql.sql-server.svc.cluster.local 1433 && echo 'TCP OK'

# SQL auth check (requires mssql-tools18 on arm64)
/opt/mssql-tools18/bin/sqlcmd \
  -S mssql.sql-server.svc.cluster.local,1433 \
  -U sa \
  -P "${MSSQL_SA_PASSWORD}" \
  -No \
  -Q "SELECT @@SERVERNAME, @@VERSION; SELECT name FROM sys.databases ORDER BY name;"
```

**Node architecture note:** The cluster has one amd64 node (`aks-sqlx64-49953808-vmss000000`, pool `sqlx64`,
Standard_D2s_v3, 2 CPU / 8 GB) hosting SQL Server, and four arm64 nodes (pools `default`, `mzdemo`).
HammerDB should be scheduled on the `sqlx64` node pool via `nodeSelector: {agentpool: sqlx64}`.
This eliminates arm64 image compatibility issues and removes inter-node network hops for the SQL
connection — directly addressing the connectivity instability goal.
Trade-off to revisit in Phase 5: HammerDB and SQL Server will compete for the same 2-CPU / 8 GB node.

Acceptance:

- ✅ AKS pod-to-SQL TCP confirmed: `nc -z` to `mssql.sql-server.svc.cluster.local:1433` succeeded.
- ✅ SQL auth confirmed: `sqlcmd` returned server name, SQL Server 2022 version, and database list from inside the cluster.

### Phase 2: Prepare HammerDB Runtime for AKS — **Status: ✅ Complete**

Goal: Run HammerDB CLI in-cluster with repo scripts available.

Steps:

1. Choose execution form:
   - Kubernetes Job for one-off benchmark cycles (recommended for now).
2. Build or reuse image strategy:
   - Option A: Use upstream HammerDB image and mount scripts via ConfigMap/volume.
   - Option B: Build a custom HammerDB image containing `scripts/hammerdb/custom`.
3. Define runtime filesystem locations for:
   - TCL scripts
   - temporary output (`tmp` equivalent)
4. Ensure non-interactive execution path (`hammerdbcli auto ...`) for build/check/run.
5. Add BCP-capable runtime support for MSSQL schema build performance:
   - Ensure `/opt/mssql-tools18/bin/bcp` is available and callable by HammerDB.
   - Export PATH in runner/job so `bcp` resolves consistently.
   - Add `MSSQL_USE_BCP=true` smoke profile option for build schema.

Deliverables:

- Initial Kubernetes manifest(s) for HammerDB job.
- Script path mapping documented.
- BCP enablement notes (runtime path + env toggle) documented.

Progress artifacts added in repo:

- `k8s/hammerdb/phase2-configmap-runner.yaml`
- `k8s/hammerdb/phase2-configmap-scripts.yaml`
- `k8s/hammerdb/phase2-job.yaml`
- `k8s/hammerdb/README.md`

Acceptance:

- ✅ HammerDB job container starts and can execute a simple CLI command.

### Phase 3: Externalize Configuration (Secrets + Config) — **Status: 🚧 In Progress**

Goal: Make configuration stable, secure, and environment-specific.

Steps:

1. Create Kubernetes Secret for SQL credentials/password.
2. Create ConfigMap for non-secret workload settings:
   - SQL host/port/db/user
   - TPROC-C VU/rampup/duration/profile values
3. Map env vars to match existing TCL expectations:
   - `MSSQL_HOST`, `MSSQL_PORT`, `MSSQL_DB`, `MSSQL_USER`, `MSSQL_SA_PASSWORD`
   - `TPROC_C_*` values
4. Add optional retry/timeout env controls to align with current script behavior.

Deliverables:

- Secret manifest template.
- ConfigMap manifest template.
- Env var contract section in docs.

Acceptance:

- HammerDB job receives all required env vars without hardcoded credentials in manifests.

### Phase 4: Add Ordered Execution Flow (Init -> Check -> Load) — **Status: ⏳ Not Started**

Goal: Guarantee deterministic run sequence in AKS.

Steps:

1. Implement entrypoint sequence:
   - Preflight TCP check to SQL Service.
   - `mssqls_tprocc_buildschema_docker.tcl`
   - `mssqls_tprocc_checkschema_docker.tcl`
   - `mssqls_tprocc_run_profile_docker.tcl`
2. Stop on first failure with clear exit code and log output.
3. Capture and persist HammerDB output files/logs.
4. Add a short smoke workload profile for first validation before full ramp-up.
5. Add BCP-first schema build mode for MSSQL smoke/standard profiles and fall back to non-BCP only when explicitly disabled.

Deliverables:

- AKS job command/entry script implementing the sequence.
- Run profiles: smoke and standard.

Acceptance:

- One complete smoke cycle succeeds end-to-end in AKS.
- Smoke cycle demonstrates materially faster schema build with BCP enabled versus non-BCP baseline.

### Phase 5: Reliability Hardening for Ramp-Up Workloads — **Status: ⏳ Not Started**

Goal: Reduce failures during higher concurrency and longer runs.

Steps:

1. Pin HammerDB pod resource requests/limits (CPU/memory).
2. Add node scheduling guidance if SQL and HammerDB should be topology-aware (same node pool/zone where appropriate).
3. Introduce retry policy for transient communication failures (bounded).
4. Tune TPROC-C ramp profile progressively (stepwise VU increases).
5. Set job-level timeout/backoff and log retention conventions.

Deliverables:

- Recommended AKS resource settings.
- Ramp progression matrix (example: low -> medium -> target).

Acceptance:

- Target load profile runs with acceptable failure rate and stable connectivity.

### Phase 6: Operational Runbook and Repeatability — **Status: ⏳ Not Started**

Goal: Make execution repeatable by any team member.

Steps:

1. Document exact `kubectl` workflow:
   - apply/update config
   - launch job
   - watch status
   - collect logs/artifacts
   - clean up
2. Add troubleshooting section for common failure signatures:
   - DNS resolution
   - login/auth issues
   - communication link failures
   - timeout behavior
3. Define minimal evidence package for each run:
   - job manifest version
   - env profile
   - logs
   - result file summary

Deliverables:

- Step-by-step runbook markdown.

Acceptance:

- A second operator can run the same test from documentation only.

## Proposed Implementation Order in This Repo

1. Add AKS planning docs (this file).
2. Add `k8s/` manifests for:
   - namespace-scoped config (ConfigMap/Secret templates)
   - HammerDB job
3. Add a small AKS-oriented wrapper script for launch/log collection.
4. Validate smoke run.
5. Iterate on resource and ramp settings.

## Initial Risks and Mitigations

1. Risk: SQL Service not exposed with stable in-cluster DNS/port.
   Mitigation: Validate/normalize Service first, avoid pod IP targeting.

2. Risk: Secret/config drift between environments.
   Mitigation: Keep explicit env var contract and per-environment overlays.

3. Risk: HammerDB job restarts hide root cause.
   Mitigation: Use clear restart/backoff policy and preserve logs/artifacts.

4. Risk: High VU overloads SQL before network effects are understood.
   Mitigation: Use staged ramp profile and baseline at lower concurrency.

5. Risk: Non-BCP schema load duration is too slow for repeatable AKS test cycles.
   Mitigation: Standardize on BCP-enabled build profile and validate BCP binary/path at job startup.

## Definition of Done (Phase Gate)

This phase is done when:

1. HammerDB runs fully inside AKS against existing SQL Server.
2. Build/check/load sequence succeeds from a documented job workflow.
3. Ramp-up test demonstrates improved connectivity stability versus local-runner approach.
4. Documentation is sufficient for repeat execution.

## Next Action

Start Phase 3 by externalizing the HammerDB AKS runtime configuration into explicit Secret and ConfigMap assets, then wire the Phase 2 Job to consume those inputs without hardcoded values in the manifest.
