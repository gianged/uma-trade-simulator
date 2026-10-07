# Uma Trade Simulator - Step 1 (problem and solution)

> Study project: low latency + unsafe Rust. Non-profit, no copyright concern.
>
> Visual sketch (Excalidraw style, mirrors this file): [Uma Trade Simulator](https://claude.ai/artifact/73Hs2Kfy3sj3PiWoiny6r7)

# The problem

Build a trading platform simulation where every Uma Musume character is a tradable instrument. 1M generated users exist and all are connected at once; 100k of them trade at any moment, and 10k per second rotate in and out of trading. The **engine alone** gets 2 CPU / 4 GiB, on purpose too small. Everything else runs outside that budget so the engine's own limits are what we see.

| Requirement | Meaning |
|---|---|
| Character data | All 173 characters: name + 1 image. Already scraped into `data/umas/` (no scraper in the codebase), loaded into Postgres |
| Users | 1M generated users stored in Postgres, each with cash + holdings |
| Connected | All 1M users hold a live WebSocket connection to the gateway at the same time (real sockets, opened by a load client) |
| Trading | 100k of the connected users trade at any moment (engine slots) |
| Rotation | 10k users per second leave trading, 10k per second join; their sockets stay open |
| Throughput | 100M order operations/s inside the engine (submit / match / cancel, fed via shared memory). Not 100M network requests/s |
| Budget | **Engine container only**: 2 CPU, 4 GiB RAM. Postgres, loadgen, session, persister, gateway, swarm all run outside it |
| Rules | Balance checked on every order; a user's open orders are cancelled when they stop trading |
| Pricing | Purely bot-driven: price moves only from demand (order flow). No fundamentals, no races |
| Interface | API only (HTTP + WebSocket). No web page |
| Runtime | Docker (compose) |
| Storage | PostgreSQL |
| Shape | Cargo workspace, multiple crates, multiple services (processes / containers) |
| Learning goal | Low latency techniques, deliberate `unsafe` where it pays |
| Purpose | **Make it break, then identify why.** Targets are deliberately past what the budget allows. A broken run is a result, not a bug to hide |

**The hard part is the numbers, not the features:**

```
100M ops/s on 1 core  = 10 ns per op   (~30-40 CPU cycles at 3-4 GHz)
100M ops/s on 2 cores = 20 ns per op per core (only if both cores match)

1 cache miss to RAM       ~ 80-100 ns  -> already 10x over budget
1 syscall                 ~ 100+ ns    -> impossible per op
1 network packet (kernel) ~ 1-5 us     -> impossible per op
1 Postgres row insert     ~ 10+ us     -> impossible per op
32 B/event * 100M/s       = 3.2 GB/s   -> cannot log every event to disk or DB

all users    1M   * 64 B = 64 MB   -> RAM only, every random lookup misses cache
online users 100k * 64 B = 6.4 MB  -> fits L3 (~8-32 MB), misses become L3 hits (~10-15 ns)
1 trade touches 2 users  -> 2 account lookups per trade

rotation 10k out / s     -> 10k cancel sweeps / s on the hot path, each user's orders removed
rotation 10k in  / s     -> 10k account loads / s from Postgres, 10k write-backs / s

1M sockets * ~4-10 KB (kernel buffers + user state) = 4-10 GB  (outside the engine budget, still real)
1M sockets from 1 client IP to 1 server port     -> max ~64k (ephemeral ports) -> need many IPs/ports
1 price push to 1M sockets  = 1M send syscalls  ~ 1-2 CPU-seconds per tick
```

Consequences that shape the whole design:
- Hot path: zero syscalls, zero allocations, zero locks, hot data in L1/L2/L3.
- Orders cannot arrive over the network at that rate -> bot traders run in `loadgen` next to the engine, fed via shared memory.
- The budget is the engine's alone, so the study is **engine-centric**: everything else gets the CPU and RAM it needs and only shows up as pressure on the engine (rotation, neighbours on the same host).
- Two layers of "online": **connected** (1M sockets on the gateway) and **trading** (100k engine slots). Measured apart.
- Engine holds **only trading users** (100k slots). Offline users live in Postgres only. This keeps the ledger in L3.
- Rotation at 10k/s is real pressure on the engine: every logout is a cancel sweep plus a slot hand-back, inside the matching thread.
- Postgres sees **aggregates, checkpoints and session moves**, never raw events.
- 100M/s, 100k trading, 10k/s rotation on 2 CPU / 4 GiB are **meant to break something**. The deliverable is a record of what broke first, at what load, and the evidence why.
- So the design must be **honest, not defensive**: sane defaults so failures are real limits (not self-inflicted bugs), every limit is a knob, every mitigation is a toggle, every failure has a counter.

# The solution

## Domain

| Concept | Is |
|---|---|
| Instrument | One character from `data/umas/umas.json` (all 173), id `u16` |
| User | Generated account in Postgres, id `u32` (1..=1_000_000), generated name |
| Slot | One trading user inside the engine: index `u32` (0..100_000) + generation `u16` |
| Account | Cash + reserved cash + holdings, one 64 B cache line per slot |
| Holding | (uma id, qty, reserved qty); few inline per account, overflow to side table |
| Session | One login -> logout span of a user (trading span; the socket outlives it) |
| Price | Fixed-point integer ticks (no floats on hot path) |
| Order | Limit / market, buy / sell, qty, slot + generation - fixed 32 B `#[repr(C)]` |
| Trade | Match result - fixed 32 B `#[repr(C)]` |
| Bot type | Per-user behavior (market maker, demand taker, contrarian, noise) - see Price formation |
| Market data | Top of book + last trade + recent volume per uma, published by the engine in shm |
| Candle | OHLCV per uma per second |

## Architecture

```
 ENGINE BUDGET: one container, cpuset = 2 dedicated cores, mem_limit = 4 GiB
 ┌──────────────────────────────── engine (process) ──────────────────────────────────┐
 │  core A: matcher (single writer of books + ledger)   core B: post-trade            │
 │  busy-poll order ring + control ring                  busy-poll trade-event ring   │
 │  -> slot gen check (stale -> reject)                  -> candles per uma per s     │
 │  -> balance check (ledger reserve)                    -> market data snapshot      │
 │  -> match (173 books, order arena)      SPSC ring        (seqlock, for bots + API) │
 │  -> settle both slots (ledger)          ───────────►  -> trade samples             │
 │  -> Login: activate slot                trade events  -> LoggedOut + checkpoint    │
 │  -> Logout: cancel sweep, release                        export                    │
 │  ledger: 100k slots, 6.4 MB, in shm                                                │
 └──────▲──────────────────▲──────────────────────────────┬───────────────┬───────────┘
        │ SPSC order ring  │ MPSC control ring            │ events ring   │ shm: market data,
        │ (shm)            │ Login / Logout / ApiOrder    │ (shm)         │ ledger (seqlock),
        │                  │                              ▼               ▼ metrics
 OUTSIDE THE BUDGET (other cores on the same host, no limits)
 ┌──────┴─────────┐  ┌─────┴───────────────────┐  ┌──────────────┐  ┌──────────────────────┐
 │ loadgen        │  │ session                 │  │ persister    │  │ gateway (API only)   │
 │ 1-2 own cores  │  │ rotation 10k in + out/s │  │ candles,     │  │ HTTP + WebSocket     │
 │ bots read      │  │ load slots from pg,     │  │ samples,     │  │ 1M sockets, ticks,   │
 │ market data,   │  │ write back drained      │  │ checkpoints  │  │ /metrics, API orders │
 │ write orders   │  │ slots                   │  │              │  │                      │
 └────────────────┘  └───────────┬─────────────┘  └──────┬───────┘  └──────────┬───────────┘
                                 └───────────────┬────────┘                     │
                                                 ▼                              │
                                ┌─────────────────────────────────┐             │
                                │ postgres: umas (+ images), 1M   │◄────────────┘ reads
                                │ users, holdings, sessions,      │
                                │ candles, samples                │
                                └─────────────────────────────────┘

 swarm (own cgroup / machine): 1M WebSocket clients ──► gateway
 seed (once): data/umas/ + generate_series ──seed.sql──► postgres
```

- **Core A does all state changes** (books + ledger): one writer, no locks, LMAX style.
- **Core B takes everything that can lag**: aggregation, market data publishing, exports. It reads trade events from core A over an SPSC ring and never writes books or ledger.
- **Market data loop**: core B publishes top of book + last trade per uma in shm; loadgen bots read it to decide what to do. This feedback is what makes prices move with demand.

## Docker layout

| Container | CPU | Memory | IPC / shm | Notes |
|---|---|---|---|---|
| `engine` | `cpuset: "2,3"` (2 dedicated cores) | `mem_limit: 4g`, no swap | `ipc: shareable`, creates the shm regions | `memlock: -1`, `IPC_LOCK` for `mlock`; **the budget** |
| `loadgen` | `cpuset` on 1-2 other cores | no limit | `ipc: "service:engine"` | outside the budget |
| `session`, `persister`, `gateway` | remaining cores | no limit | `ipc: "service:engine"` | outside the budget |
| `postgres` | remaining cores | no limit | - | `data/` mounted read-only for seeding |
| `swarm` | own cgroup or machine | no limit | - | host networking, many source IPs |

- **cpuset, not `cpus: 2`**: `cpus` is a CFS quota; busy-spinning threads burn it and get frozen until the next period. cpuset gives two real cores. Using `cpus: 2` is kept as a knob to watch that break (#4).
- **shm is charged to the engine's 4 GiB**: shm pages count against the cgroup of the process that first touches them. Engine creates and prefaults all shared regions, so rings + ledger + market data are inside its budget, on purpose.
- **Host needed**: >= 8 logical cores and >= 16 GB (engine 2 cores, loadgen 1-2, rest for Postgres / gateway / session / persister; swarm ideally elsewhere).
- **Windows host**: Docker Desktop runs containers in a WSL2 VM. cpuset refers to VM vCPUs, not physical cores; VM scheduling shows up as noise (#13). `perf` inside containers needs extra privileges (`perf_event_paranoid`, `CAP_PERFMON` / `SYS_ADMIN`).

## Price formation

- **Only demand moves price.** No fundamentals, no races, no external feed. Price per uma = last trade.
- **All 173 umas start at the same price** (e.g. 100.00); differences come only from order flow.
- **Bot types**, assigned per user at seed time:

| Bot | Does | Reads |
|---|---|---|
| Market maker | Quotes both sides around mid, skews quotes by its own inventory | top of book |
| Demand taker | Buys / sells at market when order flow leans one way (momentum) | book imbalance, recent volume |
| Contrarian | Fades big moves with limit orders | last trade vs recent average |
| Noise | Small random limit orders near mid | top of book |

- **Demand signal** = net order flow per uma (buy volume - sell volume over a short window) and book imbalance, both from the market data snapshot.
- Bots read market data with a seqlock read in loadgen; slightly stale data is fine and realistic.
- Mix of bot types is a knob: too many takers -> prices run away (band overflow #8); too many makers -> book grows (arena #7, OOM #6).

## Slot lifecycle (rotation)

```
          session loads user              engine sees Login
  FREE ──────────────────────► LOADING ──────────────────────► ACTIVE ◄── loadgen trades here
   ▲     (writes account into              (gen++, slot live)     │
   │      slot in shm)                                            │ session sends Logout
   │                                                              ▼
   │     session writes account      engine cancels open orders, DRAINING
   └──── to Postgres, frees slot ◄── releases reserves, emits   ◄─┘
          (seqlock read)              LoggedOut{slot, gen}
```

- **Slot ownership is explicit**: FREE / LOADING owned by `session`, ACTIVE / DRAINING owned by `engine`. One writer per state, handoff by message, never shared writes.
- **Generation counter** per slot: order carries `(slot, gen)`. Order for a slot that was rotated out has an old gen -> rejected, counted. No ABA, no lock.
- **Logout cancels the user's open orders** (decided). Per-slot intrusive list of resting orders, so cancel is O(own orders), not O(book).
- **loadgen** reads the slot state array (1 byte per slot, 100 KB) to pick active slots. Race with rotation is harmless: stale picks die on the gen check.
- **Rotation (decided)**: every second, 10k users leave trading and 10k random non-trading users join. Trading count stays at 100k. That is 10% of the trading set per second.
- **Picking inside 100k**: Zipf (few hot, many idle) by default; uniform as a study knob. With 6.4 MB the whole ledger fits L3 either way, so the gap shows L1/L2 vs L3, not L3 vs RAM.

## Startup / shutdown

```
seed (once)      data/umas/* + generate_series -> Postgres: 173 umas, 1M users, holdings, bot types
engine start     create + prefault shm, all 100k slots FREE, books empty, all prices 100.00
session start    log in first 100k users (bulk COPY OUT -> fill slots -> Login msgs)
loadgen start    attach to rings + market data, trade on whatever slots are ACTIVE
run              trading + rotation 10k/s + checkpoints + gateway
shutdown         session logs everyone out -> every slot drained to Postgres -> engine stops
crash            Postgres is behind by <= 1 checkpoint interval; open orders lost, reserves reset
```

## Services (processes)

| Service | Role | Budget | Hot? |
|---|---|---|---|
| `engine` | Core A: gen check, balance check, matching, settlement, login/logout. Core B: candles, market data, samples, exports | **inside** (2 cores, 4 GiB) | yes |
| `loadgen` | Bots: read market data, pick an active slot, write orders at max rate | outside, own cores | yes |
| `session` | Rotation 10k in + out per second: load users into slots, write drained slots back, session log | outside | warm |
| `persister` | Events ring -> Postgres batches; periodic checkpoint of dirty slots | outside | no |
| `gateway` | API only: 1M WebSocket connections, price ticks, REST reads, API orders, `/metrics` | outside | warm |
| `postgres` | Durable copy: umas, users, accounts, holdings, sessions, aggregates | outside | no |
| `swarm` | Load client: 1M connections, one per user | outside (own cgroup / machine) | n/a |

## API (gateway, no web page)

| Endpoint | Returns |
|---|---|
| `GET /umas` | all 173: id, names, category, color, last price |
| `GET /umas/{id}` | one uma + top of book + last trade |
| `GET /umas/{id}/image` | the PNG bytes |
| `GET /umas/{id}/candles?from&to` | 1 s candles from Postgres |
| `GET /users/{id}` | cash, holdings, trading or watching |
| `GET /leaderboard` | top N users by equity |
| `POST /orders` | place an order for a trading user (via control ring) |
| `DELETE /orders/{id}` | cancel |
| `GET /ws` | WebSocket: one frame per tick with all 173 prices; fills for this user while trading |
| `GET /metrics` | Prometheus text of every shm counter |

## Connection layer (1M sockets)

- **Connected != trading** (decided). Every user has a socket. A socket's user is trading only while `session` has it in an engine slot. Rotation moves users between "watching" and "trading"; the socket always stays open.
- **Broadcast**: core B market data snapshot -> gateway once per tick (e.g. 1/s, all 173 prices in one frame). Frame encoded **once** into a shared buffer, written to every socket. No per-socket serialization.
- **Per-connection state** in a slab, target <= 256 B: fd, user id, send cursor into the broadcast buffer, flags. No per-connection task, no per-connection heap buffer.
- **Slow consumer** (socket send buffer full): skip that tick for that socket, count it, do not queue. Too far behind -> disconnect, count it.
- **Two gateway generations, on purpose:**
  - **v1 idiomatic**: axum + one tokio task per WebSocket. Expected to break on memory well before 1M. Record where.
  - **v2 custom**: own epoll (then io_uring) reactor, connection slab, pre-encoded broadcast frames. Push it to 1M and record what breaks next.
- **OS limits that will bite** (each is a breaking point to hit, then raise): `ulimit -n` / `fs.nr_open`, `somaxconn` + SYN backlog, ephemeral port range, `tcp_rmem` / `tcp_wmem` minimums, conntrack table under Docker NAT (use host networking), kernel socket memory on the host.
- Gateway is outside the engine budget; its breaks are recorded but only matter to the engine as host neighbours (#14).

## Crates (workspace)

```
crates/
  core-types/   lib   Order, Trade, Candle, UserId, SlotRef{slot, gen}, UmaId, price; #[repr(C)] POD
  ring/         lib   SPSC + MPSC lock-free rings; heap and shared-memory backed   (unsafe)
  shm/          lib   mmap'd region, header + layout, hugepage/mlock option     (unsafe)
  orderbook/    lib   matching: arena, price ladder, intrusive lists per level
                      and per slot (for cancel on logout)                      (unsafe)
  ledger/       lib   100k slots as cache lines, slot state + gen, inline holdings
                      + overflow, seqlock per slot, dirty bitset epoch swap     (unsafe)
  marketdata/   lib   per-uma top of book, last trade, flow window; seqlock in shm
  bots/         lib   bot types, Zipf slot picker, PRNG, no alloc
  db/           lib   Postgres access, COPY BINARY in/out (tokio-postgres)
  metrics/      lib   rdtsc timing, HDR histograms, counters in shm
  net/          lib   epoll / io_uring reactor, connection slab, WebSocket framing,
                      shared pre-encoded broadcast buffer                       (unsafe)
services/
  engine/       bin   core A matcher + core B post-trade
  loadgen/      bin
  session/      bin
  persister/    bin
  gateway/      bin   API only; v1 axum, v2 on the `net` crate
  swarm/        bin   load client
database/
  db.sql              schema (database-first, no ORM)
  seed.sql            umas + images from data/, 1M users + holdings + bot types via generate_series
data/
  umas/
    umas.json         173 characters (done)
    images/*.png      1 image each, 296x389 (done)
docker/
  compose.yaml        engine cpuset + 4g, shared IPC, everything else outside the budget
```

## Where the unsafe / low latency study lives

| Area | Technique | Why it matters |
|---|---|---|
| SPSC ring | `UnsafeCell<MaybeUninit<T>>`, Acquire/Release only, cache-padded head/tail, cached remote index, batch publish | 100M+/s cross-core handoff (orders in, trade events core A -> B) |
| MPSC control ring | CAS on head, per-cell sequence number (Vyukov style) | session + gateway both send to engine |
| Shared memory | `mmap` region, `#[repr(C)]` POD only, offsets not pointers, versioned header | process + container boundary with zero copy, zero syscall |
| Order arena | Preallocated slab, `u32` indices, intrusive doubly linked lists (per level + per slot), `get_unchecked` | no alloc, no bounds checks, O(own orders) cancel |
| Price ladder | Dense array per uma indexed by tick within a price band + bitset, best price via `lzcnt`/`tzcnt` | O(1) best bid/ask, no tree walking |
| Ledger layout | `#[repr(C, align(64))]` account = 1 cache line, slot = array index, 100k slots = 6.4 MB | whole ledger fits L3, no hashing |
| Slot generation | `(slot, gen)` handle checked on every order | lock-free safety against rotation, no ABA |
| Slot state machine | FREE / LOADING / ACTIVE / DRAINING, single writer per state, handoff by message | ownership across processes without locks |
| Ledger prefetch | Prefetch both slots' lines when the order is dequeued, before matching | hides the miss behind matching work |
| Seqlock | Per-slot and per-uma version counter; writer odd/even, readers retry torn reads | consistent snapshots for checkpoints, bots, API |
| Dirty tracking | 100k-bit bitset (12.5 KB), two buffers swapped per checkpoint epoch | persister writes only changed slots |
| Connection slab | Fixed array of `#[repr(C)]` conn state, `u32` index handles, free list, no per-conn allocation | 1M conns in ~256 MB of user space |
| Broadcast buffer | Encode once into a ref-counted / epoch-reclaimed buffer, all sockets read the same bytes | 1 serialization per tick, not 1M |
| io_uring | Registered buffers + fixed files, batched submissions, raw `io_uring` crate | fewer syscalls per send at 1M fan-out |
| Memory | Hugepages, `mlock`, prefault at startup, `prefetch` | no TLB misses / page faults on hot path |
| CPU | cpuset cores, thread pinning, busy poll, no syscalls, `#[inline]`, cold paths | stable ns-level latency |
| Allocator | Counting global allocator in debug -> assert zero allocs after warmup | proves hot path is alloc free |
| Verification of unsafe | `miri` (ring, arena, ledger), `loom` (rings, seqlock, slot handoff), ASan/TSan builds | unsafe that is checked, not trusted |
| Measurement | `criterion` microbench, `perf stat`/`perf record`, HDR histogram p50/p99/p99.9 | know the number, not guess it |

## Users and ledger

- **Generated in Postgres**, not in Rust: `seed.sql` uses `generate_series(1, 1000000)` for users, fixed starting cash, a few random starting holdings each (so sellers exist from tick 0), and a bot type per user.
- **Trading user = authoritative in engine slot.** Non-trading user = authoritative in Postgres. A user is never in both as writable state.
- **Balance check (decided)**: buy reserves cash, sell reserves qty; insufficient -> reject (counted, cheap). Fill moves reserved -> settled for both sides.
- **Checkpoint (crash safety)**: persister every N s swaps the dirty bitset, reads each dirty slot with seqlock retry, `COPY` into a staging table, one `INSERT ... ON CONFLICT DO UPDATE` into `account` / `position`.
- **Logout write-back**: session reads the drained slot (no longer changing), same upsert path, plus closes the `user_session` row.
- **Login load**: session batches 10k logins per second, one query for accounts + holdings of the batch, writes slots, sends Login messages.
- **Restart**: open orders are not persisted; on reload all reserves reset to zero.

## Breaking it on purpose

Approach: run, push one knob until something gives, record which failure appeared first and its evidence, then decide: fix it, or leave it broken and move on. Leaving it broken is fine.

**Expected breaking points** (each one is a thing to find, not to prevent):

Inside the engine budget:

| # | What breaks | Symptom | Evidence (counter / tool) | Knob that triggers it |
|---|---|---|---|---|
| 1 | Matcher throughput ceiling | ops/s far below 100M | ops/s counter, `perf stat` cycles/op, IPC | always on; matching cost per op |
| 2 | Cache | ops/s collapses as working set grows | `perf stat` LLC / L1 misses per op | trading set 100k -> 1M, uniform picking, more resting orders |
| 3 | Order ring full | loadgen stalls or drops | ring occupancy, producer stall / drop count | ring size, full policy (block / drop) |
| 4 | CFS throttling | engine freezes for ms at a time | `cpu.stat` nr_throttled, throttled_usec | `cpus: 2` quota instead of cpuset |
| 5 | Core B falls behind | trade-event ring fills, matcher stalls or drops events | events ring occupancy, drop count | trade rate, sampling rate, candle work |
| 6 | Engine OOM | engine container OOM-killed | cgroup memory.stat, OOM events | arena size, ring sizes, book growth |
| 7 | Order arena exhausted | new orders rejected | arena free count, reject reason = arena | too many market makers, cancel-on-logout off |
| 8 | Price band overflow | orders outside ladder rejected | reject reason = band | too many demand takers, band width |
| 9 | Rotation races | orders hit rotated-out slots | stale gen reject count | rotation rate |
| 10 | Logout cancel storm | ops/s dips every rotation tick | cancel time per logout, ops/s per 100 ms | rotation rate, resting orders per user |
| 11 | Seqlock reader starvation | checkpoint / bots retry forever on hot slots | seqlock retry count, max retries | Zipf skew, tick rate |
| 12 | Latency tail | p99.9 spikes | HDR histogram, `perf sched` | hugepages off, `mlock` off, pinning off |
| 13 | Environment noise | jitter that is not our code | baseline run with idle engine | Docker Desktop / WSL2 vs bare Linux |
| 14 | Noisy neighbours | engine ops/s drops when outside services are busy | ops/s vs neighbour load, LLC misses | swarm on / off, gateway load, Postgres load (shared L3 + memory bandwidth) |

Outside the budget (recorded, they press on the engine):

| # | What breaks | Symptom | Evidence (counter / tool) | Knob that triggers it |
|---|---|---|---|---|
| 15 | Rotation can't hold 10k/s | trading set drifts below 100k | achieved logins / logouts per s, rotation lag | rotation rate, batch size |
| 16 | Checkpoint slower than its interval | Postgres falls behind | checkpoint duration vs interval, pg_stat | checkpoint interval, trading set size |
| 17 | gateway v1 memory | OOM-kill long before 1M | RSS per connection, connection count at death | swarm connection count |
| 18 | File descriptors | `accept` fails with EMFILE / ENFILE | accept error counter | `ulimit -n`, `fs.nr_open` |
| 19 | Ephemeral ports | swarm `connect` fails with EADDRNOTAVAIL | swarm connect error counter | source IP count, gateway port count |
| 20 | Accept storm | SYN drops, connects time out | `netstat -s` listen overflows, ramp time | swarm ramp rate, `somaxconn` |
| 21 | Kernel socket memory | host memory pressure with small gateway RSS | `/proc/net/sockstat` mem | `tcp_rmem` / `tcp_wmem`, connection count |
| 22 | Broadcast fan-out CPU | tick takes longer than tick interval | broadcast duration vs interval, sends/s | connection count, tick rate, epoll vs io_uring |
| 23 | Slow consumers | many sockets skipping ticks / disconnected | skip + slow-disconnect counters | swarm read delay |

**Toggles** (all mitigations can be switched off to watch the failure come back):
- cpuset vs `cpus` quota, thread pinning, hugepages, `mlock` + prefault, prefetch
- spin / spin-then-park wait mode
- ring full policy: block / drop
- balance check on / off
- cancel on logout on / off (off -> orders of non-trading users stay in the book, see what breaks)
- Zipf / uniform picking, trading set size, rotation rate, checkpoint interval
- bot mix (makers / takers / contrarians / noise)
- gateway v1 / v2, epoll / io_uring, connection count, ramp rate, tick rate, slow-consumer policy

**Observability** (must exist before anything can be "identified"):
- All counters live in a shm `metrics` region: plain `u64` per counter, written by the owner process only, read by anyone. No cost on hot path beyond a store.
- gateway exposes them as Prometheus text (`/metrics`).
- Every run gets a short record: knobs used, what broke first, numbers, evidence. Saved under `docs/runs/`.

## Persistence strategy (Postgres)

| Table | Written by | Rate |
|---|---|---|
| `uma` (id, slug, name_en, name_jp, category, color, image bytea, image_mime) | `seed.sql` | once |
| `app_user` (id, name, bot_type, created_at) | `seed.sql` | once, 1M rows |
| `account` (user_id, cash) | `seed.sql`, persister checkpoint, session logout | dirty trading users + 10k/s rotated |
| `position` (user_id, uma_id, qty) | same as `account` | same |
| `user_session` (user_id, login_at, logout_at) | session | ~10k rows/s |
| `candle_1s` (uma, ts, o/h/l/c, volume, trades) partitioned by day | persister | ~173 rows/s |
| `trade_sample` (1 in N trades) | persister | tunable, ~10k/s max |
| `book_snapshot` (top N levels per uma) | persister | every few s |
| `leaderboard` (top N users by equity) | persister | every few s |
| `api_order` (orders placed via the API) | gateway | API rate, all kept |

- Writer uses `COPY ... BINARY` in batches, not row inserts.
- Engine never waits on Postgres: ring full -> drop samples + count drops. Checkpoints read shm directly, engine is never blocked.
- If Postgres is slow, rotation slows down (fewer logins / logouts per second); trading does not.

## Memory budget

**Engine container (4 GiB, the budget):**

| Item | Approx |
|---|---|
| Ledger: 100k slots x 64 B + state/gen arrays | ~7 MiB |
| Ledger: holdings overflow table | ~8 MiB |
| Order arena (knob; e.g. 32M resting orders x 32 B) | ~1 GiB |
| Price ladders (173 umas x band x 2 sides) | tens of MiB |
| Order ring (loadgen -> engine) | ~64 MiB |
| Trade-event ring (core A -> core B) | ~64 MiB |
| Control ring + events ring + market data + metrics | ~50 MiB |
| Engine binary, stacks, page tables | small |
| Headroom | ~2.7 GiB -> filled by book growth until OOM (#6), on purpose |

**Outside the budget (host):** Postgres ~1.25 GiB (1M users, ~5M holdings rows, images), gateway slab ~0.3 GiB + kernel socket memory 2-4 GiB at 1M sockets, swarm similar on its side, loadgen / session / persister small.

## Character data (done)

- Source: official site `umamusume.jp/character/`, inline Nuxt JSON (`__NUXT_DATA__`) + `list_thumb` image per character.
- Scraped once by hand (script kept outside the repo), not part of the workspace.
- `data/umas/umas.json`: `id` (1..=173, site order), `slug`, `name_en`, `name_jp`, `category`, `color`, `image`, `source_url`.
- `category`: `uma` = 145, `staff` = 28 (Tracen staff; includes some uma girls like Happy Meek, plus humans like Hayakawa Tazuna). All 173 trade (decided).
- `data/umas/images/<slug>.png`: 173 PNGs, 296x389, ~24 MB total.
- Into Postgres without any Rust: `data/` mounted read-only into the postgres container, `seed.sql` reads the manifest with `pg_read_file` + `jsonb_to_recordset` and each image with `pg_read_binary_file` into `bytea`.
- `data/` stays the source of truth for reseeding; Postgres is what services read.

## Build order (runtime order, each stage runs end to end)

Every stage ends the same way: push its knob until it breaks, write the run record. A stage can stay broken.

1. `engine` alone in its budget container (cpuset 2 cores, 4 GiB): in-process loop generates + matches orders for 1 uma, prints ops/s. Smallest thing that runs and gives the first number.
2. Order book grows: arena + price ladder + all 173 umas (ids read from `data/umas/umas.json` at startup). Benchmark again.
3. Ledger: 100k slots filled in-process, balance check + settlement, Zipf vs uniform slot picking. Benchmark; this is where account cost shows.
4. `loadgen` split out into its own container: `ring` + `shm` crates, shared IPC, SPSC order ring, thread pinning. Bots now need prices from outside -> core B appears: trade-event ring + market data snapshot. Compare to stage 3.
5. Postgres: `db.sql` + `seed.sql` (umas + images from `data/`, 1M users + holdings + bot types). `session` appears: logs in the first 100k users from Postgres instead of in-process fill.
6. Rotation: slot state machine + gen check, Logout cancel sweep, `session` rotates 10k in + 10k out per second, `user_session` log. Measure ops/s with rotation on vs off.
7. `persister`: candles + samples via events ring; periodic checkpoint of dirty slots via seqlock + dirty bitset.
8. `gateway` v1 (axum, API only): all endpoints, WebSocket ticks, API orders via control ring. `swarm` appears to open connections; push until v1 dies, record the count.
9. `gateway` v2: `net` crate, epoll reactor, connection slab, shared broadcast buffer. Push `swarm` toward 1M; hit the OS limits one by one. Then io_uring, compare.
10. Break harness: all knobs + toggles from config / env, shm metrics via `/metrics`, run record template in `docs/runs/`.
11. Full break matrix: every breaking point rerun; cpuset vs `cpus` quota; neighbours on vs off (swarm, gateway, Postgres load) to see what reaches the engine through shared L3 and memory bandwidth.
12. Unsafe checks + tuning: miri/loom/sanitizers, zero-alloc assertion; fix only the breaks worth fixing, leave the rest documented.

## Roadmap

Phases group the build stages above. No dates (study project); a phase is done when its exit record exists, broken or not.

```
 M0          M1             M2             M3              M4              M5             M6
 ●───────────●──────────────●──────────────●───────────────●───────────────●──────────────●
 plan +      first number   across         durable         1M sockets      full break     verify +
 data        (in budget)    containers     platform                        matrix         final report
 (now)       stages 1-3     stage 4        stages 5-7      stages 8-9      stages 10-11   stage 12
```

| Phase | Goal | Stages | Breaks to hunt | Exit (milestone record) |
|---|---|---|---|---|
| 0 Foundation | Plan settled, data ready | - | - | **M0**: Step 1 + Step 2 plans approved; `data/umas/` (done) |
| 1 Hot path in budget | Engine container alone: match + settle as fast as possible | 1-3 | #1 ceiling, #2 cache, #6 OOM, #7 arena, #8 band | **M1**: ops/s for book only, book + ledger, Zipf vs uniform; `perf stat` per run |
| 2 Across containers | loadgen outside, core A / core B split, market data loop | 4 | #3 order ring, #5 core B behind, #12 latency tail | **M2**: cross-process ops/s vs M1, ring occupancy, p99.9 with each toggle off |
| 3 Durable platform | Postgres, 1M users, 100k trading, 10k/s rotation, checkpoints | 5-7 | #9 races, #10 cancel storm, #11 seqlock, #15 rotation, #16 checkpoint | **M3**: ops/s with rotation on vs off, achieved rotation rate, checkpoint age |
| 4 1M sockets | gateway v1 dies, v2 pushes toward 1M | 8-9 | #17-#23 | **M4**: v1 death count, v2 max sockets + first OS limit hit, epoll vs io_uring |
| 5 Full break matrix | Every knob, every toggle, neighbours on / off | 10-11 | #4 throttling, #13 noise, #14 neighbours, full rerun | **M5**: breaking-point table filled, cpuset vs quota, neighbours on vs off |
| 6 Verify + report | Unsafe code checked, chosen breaks fixed | 12 | regressions from fixes | **M6**: miri / loom / sanitizer clean, final write-up of what broke first and why |

- Phases 1-2 are the core study (unsafe + low latency). Phases 3-5 add the pressure that breaks it.
- A phase can end broken: the exit is the record, not a passing number.
- Every run record lands in `docs/runs/` (knobs, what broke first, numbers, evidence).

# Decisions

| Topic | Decided |
|---|---|
| Throughput | 100M order operations/s inside the engine, not network requests |
| Budget | 2 CPU / 4 GiB for the engine container alone; Postgres and every other service outside |
| Users | 1M in Postgres, all 1M connected at once, 100k trading |
| Rotation | 10k in + 10k out per second; sockets stay open |
| Stop trading | User's open orders are cancelled |
| Balances | Checked on every order (reserve, reject if short) |
| Pricing | Purely bot-driven, demand only; no fundamentals or races |
| Interface | API only, no web page |
| Runtime | Docker compose |
| Characters | All 173 (`uma` + `staff`) |
| Load client | `swarm` outside the budget |
| Character data | Scraped into `data/umas/`, no scraper in the codebase |

# Open questions

Ranked by how much they change the design.

1. **How does the engine use its 2 cores?** Assumed: core A matches (single writer of books + ledger), core B does post-trade (candles, market data, samples, exports). Alternative: two matchers sharded by uma - up to 2x matching, but a user's cash is shared across shards, so it needs per-shard cash splits or cross-core messages on every order. Could be a later experiment.
2. **Host machine?** Assumed >= 8 logical cores and >= 16 GB, Docker Desktop on Windows (WSL2) or Linux. Fewer cores means outside services land on the engine's cores, which breaks the "engine alone" budget.
3. **Starting state?** Assumed all 173 umas start at 100.00, every user starts with the same cash and a few random holdings. Low impact; changes only how fast prices spread.
