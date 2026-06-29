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
- **Concurrent download engine**: N connections, each pipelining up to `--depth`
  `BODY` commands, SIMD-decoding and writing segments at their byte offsets
  (`src/net/client.zig`, `src/io/writer.zig`).
- A **CLI** (`src/main.zig`) and a **decode benchmark** (`bench/`).

### Measured (16 MiB payloads, x86_64 AVX2, ReleaseFast)

yEnc decode throughput (MiB/s of decoded output):

| workload            | native (SIMD) | scalar |
|---------------------|---------------|--------|
| text (0% escapes)   | ~1400         | ~940   |
| binary (~2% esc)    | ~955          | ~875   |
| worst (100% esc)    | ~525          | ~620   |

CRC-32: ~1.4 GiB/s.  NZB parse: ~400 MiB/s.

Notes: the SIMD path uses a movemask + bitmask compaction so sparse-escape
(real binary) data stays on the vector path; pathological all-escape data falls
back to the scalar walk (so it never regresses much). `zig build bench` runs the
full suite.

## Build & test

Requires Zig **0.15.x**.

```sh
zig build              # build the CLI -> zig-out/bin/nzpull
zig build test         # run all unit/integration tests
zig build bench        # decode throughput benchmark (native vs scalar)
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
- **Concurrency**: v1 is blocking-sockets-with-pipelining (one thread per connection).
  The planned evolution is a single **io_uring** event loop driving all sockets, which
  removes per-thread overhead at high connection counts. The protocol layer is already
  decoupled from the transport to allow this swap.
- **Not yet implemented** (deferred by design): par2 verify/repair, unrar/7z unpack,
  multi-server failover, resumable on-disk queue, web UI/RPC.
- **SIMD CRC-32**: currently scalar slice-by-8 (already ~1.4 GiB/s). PCLMULQDQ/PMULL
  folding is a future optimization; note yEnc uses IEEE CRC-32, so the SSE4.2 `crc32`
  instruction (CRC-32C) is not applicable.

## Layout

```
src/nzb/     NZB model + streaming parser
src/codec/   yenc, crc32, cpu feature selection
src/net/     nntp protocol, tcp/tls transport, concurrent client
src/io/      output file writer (direct pwrite)
tests/       yenc/crc32 vectors, scripted NNTP mock
bench/       decode throughput benchmark
```
