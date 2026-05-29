# HammerDB AKS Phase 2 Runtime

This folder contains the initial AKS runtime assets for Phase 2 (SQL Server only).

## Files

- `phase2-configmap-runner.yaml`: ConfigMap containing the entry script used by the Job.
- `phase2-configmap-scripts.yaml`: ConfigMap containing the custom MSSQL HammerDB TCL scripts.
- `phase2-job.yaml`: Job manifest that starts HammerDB on the `sqlx64` node pool.
- `run-phase2.sh`: Local copy of the runner script (same logic as ConfigMap payload).

## Script Path Mapping in Container

- Runner script: `/work/runner/run-phase2.sh`
- Custom TCL scripts: `/work/scripts/hammerdb/custom/*.tcl`
- Output temp directory: `/work/tmp`
- HammerDB CLI binary: `/home/HammerDB-5.0/hammerdbcli`

## Execution Modes

The entry script supports two modes via `HAMMERDB_PHASE2_MODE`:

- `cli-check` (default): verifies HammerDB CLI starts and runs a non-interactive command.
- `build-check-run`: runs build schema, check schema, and timed run using custom TCL scripts.

The runner is fail-fast. If HammerDB logs `Error in Virtual User` or `FINISHED FAILED` in any step,
the Job exits with a non-zero code.

## Current Smoke Defaults

The current `phase2-job.yaml` smoke profile is set to avoid collisions with existing `tpcc` data:

- `MSSQL_DB=tpcc_aks_smoke`
- `TPROC_C_WAREHOUSES=2`
- `TPROC_C_VU=1`
- `TPROC_C_ALLWAREHOUSE=false`

## Apply and Run

```bash
kubectl apply -f k8s/hammerdb/phase2-configmap-runner.yaml
kubectl apply -f k8s/hammerdb/phase2-configmap-scripts.yaml
kubectl apply -f k8s/hammerdb/phase2-job.yaml

kubectl -n sql-server logs -f job/hammerdb-phase2
kubectl -n sql-server get jobs,pods -l app=hammerdb,phase=2
```

## Promote to Full Phase 2 Test

To move from CLI check to custom script execution:

1. Edit `phase2-job.yaml` and set `HAMMERDB_PHASE2_MODE=build-check-run`.
2. Recreate the job:

```bash
kubectl -n sql-server delete job hammerdb-phase2 --ignore-not-found=true
kubectl apply -f k8s/hammerdb/phase2-job.yaml
```
