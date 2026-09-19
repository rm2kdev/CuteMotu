# 828x USB protocol notebook

> Historical protocol research, including the earlier DriverKit experiment. Build numbers and validation statements below describe that research stage. For the current USB/HAL release and compatibility, see [v0.3.0 release notes](RELEASE-0.3.0.md).

Evidence is labelled **observed**, **static**, or **unverified**. “Static” means recovered by inspecting the installed driver implementation; it does not mean a packet has been sent to this device by this project.

## Observed USB identity and descriptors

Device: `07fd:0002`, string `828 TBT`, USB high speed (480 Mbps). Device class `ff`, subclass `04`, protocol `00`, device release `0047`. The release descriptor is not a confirmed firmware version. Configuration 1 has interface 0, class `ff`, subclass `04`, protocol `ff`.

| Alternate | `01` OUT | `82` IN | `03` OUT | `84` IN | `85` IN |
| --- | --- | --- | --- | --- | --- |
| 0 | Interrupt 256 B | Interrupt 256 B | — | — | — |
| 1 | Interrupt 256 B | Interrupt 256 B | Isochronous 960 B | Isochronous 960 B | Interrupt 4 B |
| 2 | Interrupt 256 B | Interrupt 256 B | Isochronous 1536 B | Isochronous 960 B | Interrupt 4 B |
| 3 | Interrupt 256 B | Interrupt 256 B | Isochronous 960 B | Isochronous 1920 B | Interrupt 4 B |
| 4 | Interrupt 256 B | Interrupt 256 B | Isochronous 1536 B | Isochronous 1920 B | Interrupt 4 B |

All capacities above are per service interval. Endpoints `01/82` have `bInterval=4` (1 ms); `03/84/85` have `bInterval=1` (125 µs). High-bandwidth capacity must account for the transaction multiplier: `wMaxPacketSize=0b00` means two transactions of 768 bytes, and `0bc0` means two of 960 bytes. These are maximum transfer sizes, not fixed packet lengths.

The live driver had alternate 1 selected at inspection. Alternate 0 is not proof that register access works before hardware initialisation. The 0.2 extension selects alternate 1 before obtaining its pipes. Cold-device initialisation still needs hardware validation.

## Register messages — static evidence and live verification

Named routines inspected include `USBBusCommand::GetAddress`, `com_motu_driver_FWA_USBProvider::SendNextCommand`, `ReadComplete`, `InitHardware`, and the response-data constructor. The observed USB interface supports the endpoint organisation used by those routines; live 0.4.0 tests confirmed the firmware, clock and optical read replies and stream-control acknowledgements.

### Read request on endpoint `01`

Exactly 6 bytes:

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 1 | Sequence |
| 1 | 1 | Operation `04` |
| 2 | 4 | Register address, little endian |

Example request for address `f0000000`, sequence 1: `01 04 00 00 00 f0`.

### Read reply on endpoint `82`

Exactly 12 bytes in the inspected implementation:

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 1 | Sequence |
| 1 | 1 | Operation `06` |
| 2 | 1 | Status; zero/nonzero is checked by the vendor code |
| 3 | 1 | Reserved/unknown |
| 4 | 4 | Register address, little endian |
| 8 | 4 | Value, little endian |

This project requires matching sequence, operation, address, exact message length and zero status. Nonzero status is conservatively treated as failure; its full meaning is unverified. Unrelated notifications are ignored without extending the deadline. Fragmentation, multiple replies per transfer, and other firmware revisions are not implemented.

### Write request and acknowledgement

Static layout: write operation `00`, 12 bytes: sequence at 0; operation at 1; zero bytes at 2–3; little-endian address at 4; little-endian value at 8. The acknowledgement operation is `02`, 7 bytes: sequence at 0, operation at 1, status at 2, address at 3.

The extension uses acknowledged writes for stream control and the PCM-fetch bit. It exposes no arbitrary-register user client. DSP block writes are implemented through a separately validated control user client; see [CueMix protocol](../src/Control/MOTUDSP.cpp).

### Register candidates and notifications

`InitHardware` reads `f0000000` during firmware identification and `f0000004` during GUID handling. The extension reads the former during startup. Its version encoding remains unknown; GUID-derived multi-device identities are not implemented.

The vendor receive path also examines operation `00`, address `00222200`, and operation `01`, address `00444400`, as notifications. They are not interpreted by this build. The four-byte interrupt endpoint `85` must not be assumed equivalent to the six-byte notification packets in the newer Linux Pro Audio driver.

## Streaming profile — measured input, experimental output

The 48 kHz input stream has **120-byte sample frames**, eight per **960-byte nonempty USB packet**. This was measured using both IOUSBHost frame-list and transaction-list captures. The earlier assumption of 108 bytes in both directions was wrong. The first 12 bytes contain timestamps/status; this implementation decodes 32 packed big-endian signed 24-bit PCM channels beginning at byte 12. The remaining input bytes and physical channel mapping still need signal tests.

**Playback failed live validation in build 17: the user reported a high-pitched sound and Main Left peaking during intended silence.** USB completion alone cannot validate the format or timing. Subsequent streaming builds have an automatic test deadline.

Output currently uses **108-byte frames**, containing a 12-byte header, 30 PCM channels and six padding bytes. This follows static analysis of the installed driver's hybrid-model slot rounding; accepted USB transfers alone do not verify the device's interpretation or audible output.

`USBOutputBuffer::SetHeaders` writes big-endian timestamps at byte 0. `USBInputBuffer::GetSampleTimeStamp` reads them. `Box::PrepareIsoc` selects eight samples per packet at the base rate; `USBOutputBuffer::Init` computes the fixed packet byte count. The extension sends **864-byte packets**, with empty microframes to average six packets per millisecond. Isochronous request buffer offsets advance by requested counts, including zero-length output entries.

Input and output MIDI use **data byte 9**, **flag byte 10, bit 0**. The relevant routines are `InputBufferWatcherFxDSP::Init`, `InputBufferWatcherMIDI::DoMidi`, `USBOutputProgram::Init`, and `OutputBuffer::WriteMidiByte`. Other MOTU models select different offsets. The remaining status bits are not repurposed by this implementation.

### Clock reconstruction

`USBProvider::InitHardware` constructs its converter with a 60 MHz clock. Live captures normally advance 1,250 ticks per sample, occasionally 1,251. Validation allows four ticks of quantization error and re-anchors at every packet; it still rejects a missing full sample. The 32-bit counter is extended through wrap.

In `USBProvider::IsocReadComplete`, byte 4 carries one byte of a USB clock reference. Byte 5 bit 2 marks a valid fragment; bits 0–1 identify fragments 0–3. Four consecutive fragments assemble a little-endian 32-bit device tick. The upper five bits of the final fragment's byte 5 identify the referenced USB microframe modulo 32; the reference is strictly before the containing microframe. The decoder does not join fragments across packet boundaries.

The extension maps these references through `IOUSBHostInterface::ReferenceMicroframe`'s bus/host correlation, refreshed every 100 ms, estimates the device-to-host slope and waits for two references and 32 timestamp observations before publishing audio/MIDI. Controller references may be cached more than a second behind current time. Piecewise correlation preserves previously mapped input and queued output timestamps while applying new slope corrections beyond them. Core Audio zero timestamps advance once per 4,096-frame ring wrap from the recovered hardware timeline; the earlier 128-frame period caused host timeline resets. There is no synthetic timer-driven audio clock. The timer refreshes the bus/host correlation and enforces watchdog and bounded-test deadlines. Build 26 sets output presentation 24 sample frames (0.5 ms) after the scheduled USB boundary, matching the hybrid model’s four-cycle prequeue; the host queue remains 16 ms. This replaces the earlier incorrect 768-frame device lead; the initial safety offsets are 512 input and 2,048 output frames.

A header-only fixture from 46 captured packets verifies reference decoding and timestamp lock across 368 samples. Long-term drift and output presentation lead remain unverified. Endpoint 85 is not read by this version; the embedded references are used instead.

### Startup and failure handling

1. Validate the complete observed USB descriptor profile, open the interface and select alternate 1.
2. Read firmware `f0000000`, clock `f0000b14`, and optical configuration `f0000c94` with distinct sequence numbers.
3. Require clock low 16 bits `0100` (48 kHz internal) and optical mask `00550303` equal to `00000303` (ADAT A/B in/out).
4. Queue incoming isochronous reads; acknowledge stream control `00c00000` to register `f0000b00`.
5. Wait for the incoming clock to lock, with a three-second deadline.
6. Acknowledge `c0c00000` to the stream-control register, then set bit `02000000` in the saved clock register to enable fetching PCM.
7. Queue output and publish the Core Audio device and MIDI child service.

The stream-control constants are from `Box::StartIsoc`, `Box::StopIsoc` and `BoxWithFxDSP::SendIsocControlWord`. Clock and optical fields are also described in Linux's legacy MOTU protocol-v3 implementation; the live device acknowledged these startup and stop writes. Main L/R playback and Mic 1 capture have been physically verified; the remaining signal paths still need hardware tests.

Each command requires a matching sequence, operation, address, zero status, exact reply length and successful complete OUT transfer. Its one-second deadline does not extend for notifications. If the first firmware read times out, it is cancelled and drained before one read-only retry; this recovery has passed repeated live runs without a USB reconnect. Writes are never retried. The session never wraps sequence IDs. Eight 2 ms buffers are preallocated and queued in each direction; no callback allocates a USB buffer. Actions and memory descriptors survive aborted completions, and a generation guard rejects obsolete callbacks.

Missing input for 500 ms, a clock discontinuity, a malformed packet or failed transfer takes the device offline. Recovery drains control I/O and attempts `80800000` to the stream-control register, bounded by 200 ms, then closes the interface. Provider termination closes/aborts immediately; a disconnected device cannot acknowledge a stop command. Automatic restart and sleep/wake recovery are outside this milestone.

### MIDI and channel mapping limits

One DIN source and destination are published via MIDIDriverKit in the same extension process. MIDI bytes share audio transport; the transport therefore stays active with silence when audio clients stop. Output is paced at 3,125 bytes/second (31,250 baud, ten serial bits per byte). Queue publication is transactional per UMP batch. Full queues and concurrent producer calls report errors rather than dropping partial messages silently.

Build 28 translates logical playback order to USB wire order at `packFrame`; the HAL buffers and playback ring stay in logical order. Input decoding is unchanged. All channel numbers below are one-based.

| App output | Destination | USB PCM slots |
| --- | --- | --- |
| 1–2 | Main L/R | 11–12 |
| 3–10 | Analogue 1–8 | 3–10 |
| 11–12 | Phones | 1–2 |
| 13–14 | S/PDIF | 13–14 |
| 15–22 | ADAT A | 15–22 |
| 23–30 | ADAT B | 23–30 |

Physical tests verify wire outputs 11/12 as Main L/R, analogue meter activity for the user’s tested pairs, and input 1 as Mic 1. The remaining physical output destinations, converter latency, MIDI round-trip timing and SysEx reliability must be measured. No channel is duplicated or mixed into another output. UMP MIDI 2, groups other than zero and timestamp/utility packets are not supported.

## Builds 37–38: replacement startup

A replacement can observe clock word `02000100`, with fetching inherited from the earlier process. Startup now cycles an inherited nonzero USB alternate through 0, then selects 1, reads/validates the existing profile, acknowledges stream stop `80800000`, and clears only fetch bit `02000000`. It starts input transfers, acknowledges warm `00c00000`, acquires an initial clock, acknowledges run `c0c00000`, enables fetching and reacquires clock timing before starting output or publishing devices. The final phase waits at least two seconds and requires 500 ms of uninterrupted valid timing, bounded by ten seconds.

Normal Stop attempts hardware stop and fetch clear before interface close; all paths still use the existing asynchronous cancellation barrier. Provider termination can make the control pipe unavailable, so startup normalization remains mandatory. Both build 37 and build 38 read inherited fetch-enabled clock words and started without a physical reconnect. Broader recovery is not inferred from these two observations.
