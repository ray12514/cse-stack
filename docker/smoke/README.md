# Local Docker end-to-end smoke

This directory is a local-only harness for testing the current stack pipeline:

```text
cluster-inspector profile
  -> stack-composer render
  -> stack-content templates
  -> spack-build
  -> Spack concretize/fetch/install/verify
```

The directory is intentionally ignored by the main `cse-stack` repository. Do
not push this harness as part of the old `cse-stack` project unless that project
is explicitly repurposed.

## Expected neighboring repositories

By default, `run-smoke.sh` assumes these repositories live under the same
`~/Development` directory:

```text
cluster-inspector/
stack-composer/
stack-content/
cse-stack/
```

Override paths if needed:

```bash
DEV_ROOT=/path/to/Development \
CI_DIR=/path/to/cluster-inspector \
SC_DIR=/path/to/stack-composer \
CONTENT_DIR=/path/to/stack-content \
RUNTIME_DIR=/path/to/smoke-runtime \
./docker/smoke/run-smoke.sh pipeline
```

## Commands

From the `cse-stack` repo root:

```bash
./docker/smoke/run-smoke.sh build              # build Rocky/Spack image
./docker/smoke/run-smoke.sh cluster-inspector  # build Linux cluster-inspector binary
./docker/smoke/run-smoke.sh pyz                # build stack-composer.pyz + copy spack-build
./docker/smoke/run-smoke.sh profile            # generate profile.yaml inside container
./docker/smoke/run-smoke.sh render             # render workspace using stack-content
./docker/smoke/run-smoke.sh build-step         # concretize/fetch/install/verify with Spack
./docker/smoke/run-smoke.sh pipeline           # profile + render + build-step
```

The default image uses Rocky 9 and Spack `v1.1.1`.

## Current passing baseline

The current baseline is a single CPU lane:

```text
stack: cse-smoke
lane:  gcc-core
spec:  zlib@1.3.1
```

Expected final report:

```yaml
verification:
  spack_verify_libraries: passed
  spack_verify_manifest: passed
```

Reports are written under:

```text
$RUNTIME_DIR/reports
```

The default runtime directory is:

```text
~/Development/smoke-runtime
```

## Notes for future agents

- `run-smoke.sh` should fail if `spack-build` fails. Do not mask that exit code.
- If render fails with stale schema fields, refresh `$RUNTIME_DIR/stack.yaml`
  from `docker/smoke/stack.yaml`.
- The runtime tree is persistent by design so Spack installs and source cache can
  be reused between runs.
- Use `run-smoke.sh clean` to wipe generated workspace/reports while preserving
  the persistent install/source-cache directories.
