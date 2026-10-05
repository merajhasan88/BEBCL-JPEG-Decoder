# Roadmap: proposals and tasks

Development branch only (not exported to the library). Recorded on 2026-10-04 at the owner's
request; the names are the owner's.

| item | what | state |
|---|---|---|
| **Proposal A** | split the stream of one image that has no restart markers, so several decoders can share one photo | research started 2026-10-04 after 22:40 PKT (owner: "sure go ahead keeping in mind the load on the laptop's cores") |
| **Proposal B** | a way around the Huffman loop limit (one code per clock) | research started with A, in parallel |
| **Task A** | batched mode of the wide core on fpgas.online Welland | **done 2026-10-05**: 15 wide decoders at 150 MHz (-3 grade), 18/18 identical to libjpeg 9e on the board, 372 photos/s on adapter.jpg; details below and in `boards/acorn_cle215/README.md` |
| **Task B** | all tests on AWS F2 | last; nothing is set up on AWS without the owner's go-ahead |

Research, measurements, estimates and the plan for both proposals: `PROPOSALS.md`.

Method for both proposals (the order the owner chose for the wide core, "model first"): published
methods and existing decoders, then estimates with `model/perf`, then a plan with numbers for the
owner, and RTL only after that. The output must stay bit-exact (libjpeg 9e and Pillow profiles).

## Proposal A: split a stream without restart markers

Owner: "Lets find a way to split a stream of an image without restart markers."

- **Why.** None of the owner's 24 photo files (`test_images/` and their 4:2:0 copies) has a restart
  interval (no DRI marker), so each photo is one entropy-coded segment that one decoder must read in
  order. A bigger FPGA alone cannot shorten one photo.
- **What a decoder starting in the middle of the stream must recover:** the bit position of the next
  code, its place in the MCU (component, block, coefficient index), and the DC predictor of each
  component (DC values are coded as differences from the previous block of the same component,
  T.81 F.2.2.1).
- **Starting points:** the self-synchronisation of Huffman codes (a decoder started at a wrong bit
  position tends to fall back into step), the speculative parallel decoders used for JPEG on GPUs,
  and fixing up the DC predictors afterwards (a prefix sum of the differences).

## Proposal B: a way around the Huffman loop limit

Owner: "In parallel (pun intended) lets find a way around Huffman loop limitation".

- **The limit.** Each code's length must be known before the next code can start, so the loop (table
  lookup, code length, shift, next lookup) cannot be split into more pipeline stages. The wide core
  (`FAST=2`) decodes one code per clock and closes timing at 150 MHz on the Artix-7 XC7A200T-3;
  estimate 250-350 MHz on the fastest FPGAs.
- **Target.** The fastest desktop CPU core decodes about 2.04x as fast as the laptop's i7-8550U
  (libjpeg-turbo tjbench on OpenBenchmarking: Core Ultra 9 285K 359 vs 176 Mpixel/s), so the wide
  core would need about 270 MHz to beat it on every photo (estimate; at 150 MHz it takes 1.31-1.80x
  that core's time, against 0.64-0.88x of the laptop core's, measured).
- **Ideas to study:** decoding two or more codes per lookup; decoding speculatively at several bit
  positions and keeping the right result; together with Proposal A, letting independent pieces of a
  photo take turns in a loop with more pipeline stages.

## Task A: batched mode of the wide core on Welland

- **Result (2026-10-05).** 15 wide decoders (`boards/acorn_cle215`: `uart_batch_core.sv`,
  `results_batch_2026-10-05.json`), 91,949 LUTs and 495 DSPs, 150 MHz met for the board's -3 grade
  (141.5 MHz on -2). On the board: adapter.jpg broadcast to all 15 lanes, then three photos in three
  lanes - 18/18 identical to libjpeg 9e with every clock count equal to the simulation: 15 photos in
  40.33 ms, 372 photos/s, 20.7x one laptop core. A 133 MHz build for the -2 grade is in progress.
- **What.** Several wide decoders side by side on one FPGA, each decoding its own photo: throughput
  rather than single-photo time. Owner: "We do have to use that website for the batched mode that is
  deferred at the moment".
- **Board.** SQRL Acorn CLE-215+ (Artix-7 XC7A200T-3) at fpgas.online Welland, `pi-sw2-p46`
  (`pi-sw2-p47` is the same board).
- **Room.** One wide decoder with the test harness takes 6,211 LUTs, 33 DSPs and 9 block-RAM tiles of
  the XC7A200T's 133,800 LUTs, 740 DSPs and 365 tiles: LUTs and DSPs would allow about 20, but each
  lane's gated clock takes a global clock buffer, and the clock generator (MMCM) can drive only the 16
  buffers of its half of the chip: 15 lanes plus the core clock (16 lanes synthesized to 73 % of the
  LUTs, then failed clock placement). More lanes would need a second MMCM in the other half.
- **Open questions.** How to feed many decoders through the board's 1 Mbaud UART (each decoder's
  clock stays gated while it waits for data, as in the current harness, so the clock counts still
  measure decoding only); how to report the results per decoder.
- **Rules for fpgas.online.** Ask the owner before every run; check that the board is free; one
  terminal session per run, slow polling, delete everything afterwards; upload only photos from
  `test_images/` (and their 4:2:0 copies); no remote-board tools in the repositories.

## Task B: all tests on AWS F2

- **When.** Last (owner: "I want to test AWS last"); nothing is set up on AWS without the owner's
  go-ahead.
- **Setup agreed on 2026-10-04.**
  - One f2.6xlarge: one VU47P FPGA, $1.98/h, needs 24 vCPUs of the "Running On-Demand F instances"
    quota (requested by the owner on 2026-10-04).
  - A separate build instance with AWS's FPGA Developer AMI (~$0.5-1/h). Vivado comes licensed
    there for the VU47P; the F2 kit supports Vivado 2024.1-2025.2, not our local 2026.1.
  - No Elastic IP. Every instance and its disks are deleted after each run, nothing is left running
    between rebuilds; the S3 bucket may stay.
  - Budget: ~$2-4 per attempt (build 1.5-3 h, AFI creation 0.5-1 h on AWS's side with no instance
    running, ~0.5 h on the F2).
- **Prepared locally first,** so that the first attempt works: a `boards/aws_f2` harness and host
  program, simulated with Verilator; a timing preview on an UltraScale+ part if the free Vivado
  licence covers one.
- **Clock.** The F2 shell offers 15.625-500 MHz; the wide core is estimated at 225-250 MHz on the
  VU47P.
- **"All tests" (owner, 2026-10-04):** all 24 photo files on the single core (`FAST=1`), the wide
  core (`FAST=2`) and the batched mode, plus whatever comes out of Proposals A and B; checked against
  libjpeg 9e's checksums and the simulated clock counts, as on Welland.
