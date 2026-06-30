# NZpull

A high-performance NZB (Usenet) downloader written in Zig. NZpull's focus is raw
throughput: **SIMD-accelerated yEnc decoding**, **NNTP command pipelining**, and a
concurrent **direct-write-at-offset** I/O path.

It is a from-scratch implementation; the C++ `nzbget` in the parent repository was
used only as a reference for the problem domain (NNTP flow, the yEnc/CRC hot paths,
direct write to disk).

## Status (v1)

Implemented and tested end-to-end:

- Streaming, dependency-free **NZB parser** (`src/nzb/`).
- **yEnc decoder** with a native `@Vector` SIMD fast path and a scalar reference
  (`src/codec/yenc.zig`).
- **CRC-32 (IEEE)** slice-by-8 with zlib-style `combine()` for stitching per-segment
  CRCs (`src/codec/crc32.zig`).
- **NNTP protocol** layer over a small injectable stream interface — greeting,
  AUTHINFO, GROUP, multiline body framing + dot-unstuffing, and pipelined `BODY`
  (`src/net/nntp.zig`).
- **TCP and TLS transports** (`src/net/transport.zig`).
- Two interchangeable **download engines** (select with `--engine`):
  - `threads` (default): N connections, one OS thread each, blocking sockets, each
    pipelining up to `--depth` `BODY` commands (`src/net/client.zig`).
  - `iouring` (Linux, TCP-only): a single io_uring event loop drives all sockets;
    yEnc decode + CRC + disk write are offloaded to a worker pool, with a bounded
    buffer pool providing backpressure (`src/net/io_engine.zig`,
    `src/net/eventloop.zig`, `src/net/async_conn.zig`, `src/net/decode_pool.zig`).
- SIMD-decode + write segments at their byte offsets (`src/io/writer.zig`).
- A **CLI** (`src/main.zig`), a **decode benchmark** (`zig build bench`), and a
  **loopback network benchmark** (`zig build bench-net`).

### Measured (16 MiB payloads, x86_64 AVX2+PCLMUL, ReleaseFast)

yEnc decode **+ CRC verify** throughput (MiB/s of decoded output):

| workload            | native (SIMD) | scalar |
|---------------------|---------------|--------|
| text (0% escapes)   | ~2750         | ~800   |
| binary (~2% esc)    | ~1300         | ~710   |
| worst (100% esc)    | ~520          | ~590   |

CRC-32 standalone: **~8 GiB/s** (PCLMULQDQ fold-by-4).  NZB parse: ~400 MiB/s.

Notes:
- The yEnc SIMD path uses a movemask + bitmask compaction so sparse-escape (real
  binary) data stays on the vector path; pathological all-escape data falls back
  to the scalar walk (so it never regresses much).
- CRC-32 uses a PCLMULQDQ fold-by-4 loop with four independent accumulators to
  hide carry-less-multiply latency; all fold constants are derived at comptime
  from the polynomial (no magic numbers) and verified against the scalar table
  for every length in tests. Non-x86 / no-PCLMUL targets use slice-by-8.

`zig build bench` runs the full suite.

### Engines (loopback benchmark, `zig build bench-net`, 256 MiB)

| engine  | 16 conns | 64 conns |
|---------|----------|----------|
| threads | ~2100 MiB/s | ~1600 MiB/s |
| iouring | ~1100 MiB/s | ~700 MiB/s |

Both engines download and CRC-verify identically (0 failures). On **zero-latency
loopback** the thread engine wins: there's no network latency for async to hide,
and the io_uring path currently does extra buffer copies (recv buffer → carry
buffer → article buffer) and reads one outstanding `recv` per connection. The
io_uring engine's intended advantages — tolerating real WAN round-trip latency and
far lower per-connection cost at hundreds of connections — don't show on loopback.
Next optimizations: parse straight from the recv buffer (drop a copy), keep
multiple `recv`s in flight, and batch submits. Until then, `threads` stays the
default.

## Build & test

Requires Zig **0.15.x**.

```sh
zig build              # build the CLI -> zig-out/bin/nzpull
zig build test         # run all unit/integration tests
zig build bench        # decode throughput benchmark (native vs scalar)
zig build bench-net    # loopback network benchmark (threads vs iouring)
zig build run -- ...   # build and run the CLI
```

Backend selection (yEnc/CRC): `-Ddecoder=native` (default) or `-Ddecoder=scalar`.
`rapidyenc` is reserved as a future C-binding option for A/B benchmarking.

## Usage

```sh
# Summarize an NZB without downloading:
nzpull file.nzb --info

# Download (credentials may come from env: NZPULL_HOST/NZPULL_USER/NZPULL_PASS):
nzpull file.nzb --host news.example.com --port 563 --tls \
    --user alice --pass secret --conn 16 --depth 8 --out ./downloads
```

| Option     | Meaning                                            |
|------------|----------------------------------------------------|
| `--out`    | output directory (default `.`)                     |
| `--host`   | news server host (`NZPULL_HOST`)                   |
| `--port`   | port (default 119, or 563 with `--tls`)            |
| `--user`   | username (`NZPULL_USER`)                            |
| `--pass`   | password (`NZPULL_PASS`)                            |
| `--tls`    | use TLS                                             |
| `--conn`   | number of connections (default 8)                  |
| `--depth`  | pipeline depth per connection (default 4)          |
| `--engine` | `threads` (default) or `iouring` (Linux, non-TLS)  |
| `--info`   | parse + summarize only                             |

## Architecture

```
 NZB ──▶ parser ──▶ flat segment job queue (atomic cursor)
                          │
        ┌─────────────────┴─────────────────┐
        ▼                                     ▼
   worker thread × N            (1 connection = 1 pipelined NNTP session)
     • issue up to D BODY cmds back-to-back   (pipelining)
     • read D responses in FIFO order
     • SIMD yEnc decode + CRC-32 verify
     • pwrite decoded bytes at the part's byte offset
```

Fetching is by **Message-ID** (`BODY <id>`), which is globally unique and needs no
`GROUP` selection — this keeps the pipeline simple. Positional writes (`pwrite`) from
multiple threads to disjoint offsets need no locking and avoid a final concat pass.

## Known limitations / roadmap

- **TLS**: uses `std.crypto.tls.Client` (TLS 1.2/1.3). CA verification is currently
  disabled (`.ca = .no_verification`) — fine for testing, **not** for untrusted
  networks. A CA-bundle option (or a C TLS binding) is the next step.
- **Concurrency**: both a thread-per-connection engine and a single-thread **io_uring**
  engine exist (`--engine`). The io_uring engine works and verifies correctly but is
  not yet faster on loopback (see "Engines" above); reducing its copies and keeping
  multiple reads in flight is the next optimization before it becomes the default.
- **Not yet implemented** (deferred by design): par2 verify/repair, unrar/7z unpack,
  multi-server failover, resumable on-disk queue, web UI/RPC.
- **CRC-32**: PCLMULQDQ fold-by-4 implemented for x86_64 (~8 GiB/s); slice-by-8
  fallback elsewhere. An ARM PMULL path is a future addition. (yEnc uses IEEE
  CRC-32, so the SSE4.2 `crc32` instruction — CRC-32C — is not applicable.)

## Layout

```
src/nzb/     NZB model + streaming parser
src/codec/   yenc, crc32, cpu feature selection
src/net/     nntp protocol, tcp/tls transport, concurrent client
src/io/      output file writer (direct pwrite)
tests/       yenc/crc32 vectors, scripted NNTP mock
bench/       decode throughput benchmark
```
