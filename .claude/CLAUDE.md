# uma-trade-simulator

Study project: a trading simulator where all 173 Uma Musume characters are instruments, built to find
where a low-latency Rust engine breaks (target 100M order ops/s on 2 CPU / 4 GiB). Rust workspace,
Docker compose, PostgreSQL. Source of truth: `docs/plans/uma-trade-simulator.md` (greenfield).

## Commands
<!-- proposed; replace with real ones once Cargo.toml / compose.yaml exist -->
- Build: `cargo build --workspace --release`
- Lint: `cargo clippy --workspace --all-targets -- -D warnings`
- Test: `cargo test --workspace`
- Unsafe checks: `cargo +nightly miri test -p ring -p ledger -p orderbook`
- Run: `docker compose -f docker/compose.yaml up`

## Architecture
- `crates/`: libraries; `ring`, `shm`, `orderbook`, `ledger`, `net` hold the `unsafe` code
- `services/`: binaries (`engine`, `loadgen`, `session`, `persister`, `gateway`, `swarm`)
- `database/`: `db.sql` + `seed.sql`, database-first, no ORM; seed reads `data/` via `pg_read_file`
- `data/umas/`: scraped character data (173). Static input, no scraper in the repo; never regenerate
- `docs/runs/`: one record per break run (knobs, what broke first, numbers, evidence)

## Conventions
- Breaking is the goal: never add a silent mitigation. Every mitigation is a toggle, every limit a
  knob, every failure a `u64` counter in the shm metrics region.
- Engine hot path (core A): no allocation, no syscall, no lock, no `std::sync::Mutex`, no logging.
- Types crossing shared memory are `#[repr(C)]` plain-old-data with offsets, never pointers or `Vec`/`String`.
- Only `engine` writes books and ledger; other processes read shm via seqlock.
- Every `unsafe` block carries a `// SAFETY:` comment.
- Only the `engine` container gets the budget (`cpuset` 2 cores, `mem_limit: 4g`); never place
  another service on its cores.
- Postgres via `tokio-postgres` with `COPY ... BINARY` for bulk writes.
- Errors: `thiserror` in `crates/`, `anyhow` in `services/`.
- Modules: sibling `foo.rs` + `foo/`, never `foo/mod.rs`.

## Gotchas
- Target is Linux (mmap, mlock, hugepages, io_uring, CPU affinity). The dev host is Windows:
  lint, test and run inside WSL2 or the containers, not on the Windows host.
- Docker Desktop: `cpuset` maps to WSL2 vCPUs, not physical cores; `perf` in a container needs
  `CAP_PERFMON` or `--privileged`.
- Shared-memory pages count against the memory limit of whichever container touches them first.
  `engine` creates and prefaults them on purpose.
