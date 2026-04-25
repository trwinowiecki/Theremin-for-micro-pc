# Raspberry Pi Theremin — Project Reference

## Overview

A digital theremin built on a **Raspberry Pi Zero 2 W** using a **CD4069 hex inverter** chip as a dual Colpitts oscillator. The oscillator frequencies shift as hands approach two antennas (pitch and volume). The Pi samples these frequencies via SPI, computes a beat frequency, and synthesizes audio output via ALSA.

Based on the simulistics.com project and its associated GitHub repository. Uses the **SPI circuit variant** (no 74HC74 latch chip).

---

## Hardware

### Raspberry Pi Zero 2 W (BCM2710)

- Runs Raspberry Pi OS (Bookworm, aarch64)
- SPI0 and SPI1 both active
- I2C bus available for future LCD integration

### CD4069 Hex Inverter — Oscillator Circuit

Two identical Colpitts oscillators, one per antenna:

**Pitch oscillator (left side of chip):**

- Inverter 1 (pins 1/2): oscillator core
  - 1MΩ feedback resistor between pin 1 (input) and pin 2 (output)
  - 100pF cap from pin 2 to GND
  - 470pF cap from pin 2 to GND
  - 100kΩ isolation resistor from pin 2 to antenna
  - 1nF "antenna tap" cap from the pin 2 / 100kΩ junction to GND
- Inverter 2 (pins 3/4): buffer
  - Pin 3 connected directly to pin 2 (buffer input = oscillator output)
  - Pin 4 (buffer output) → GPIO 9 on Pi

**Volume oscillator (right side of chip, mirror image):**

- Inverter 6 (pins 13/12): oscillator core
  - 1MΩ feedback resistor between pin 13 (input) and pin 12 (output)
  - 100pF cap from pin 12 to GND
  - 470pF cap from pin 12 to GND
  - 100kΩ isolation resistor from pin 12 to antenna
  - 1nF "antenna tap" cap from the pin 12 / 100kΩ junction to GND
- Inverter 5 (pins 11/10): buffer
  - Pin 11 connected directly to pin 12
  - Pin 10 (buffer output) → GPIO 19 on Pi

**Chip power:**

- Pin 14 → 3.3V
- Pin 7 → GND
- 100nF decoupling cap between pins 14 and 7 (close to chip)

### PWM Audio Output

Uses the `audremap` overlay to create an ALSA sound card on GPIO pins:

- GPIO 12 (physical pin 32) → right channel
- GPIO 13 (physical pin 33) → left channel

Each channel has an RC low-pass filter:

```
GPIO pin ──[10kΩ]──┬── 3.5mm cable signal wire
                   │
                [100nF]
                   │
                  GND
```

3.5mm cable wire colors (non-standard — verified by continuity testing):

- Green = left signal (tip)
- White = right signal (ring 1)
- Black = mic (ring 2) — disconnected
- Red = ground (sleeve)

### Future: 16×2 I2C LCD (HD44780 with I2C backpack)

- I2C address: likely 0x27 or 0x3f (to be confirmed with `i2cdetect`)
- SDA → GPIO 2 (physical pin 3)
- SCL → GPIO 3 (physical pin 5)
- Will use RPLCD Python library, communicating with the C program via Unix socket

---

## GPIO Pin Assignments

| GPIO | Physical Pin | Function |
|------|-------------|----------|
| 2 | 3 | I2C SDA (reserved for LCD) |
| 3 | 5 | I2C SCL (reserved for LCD) |
| 9 | 21 | SPI0 MISO — pitch oscillator input |
| 12 | 32 | PWM audio right channel |
| 13 | 33 | PWM audio left channel |
| 16 | 36 | SPI1 CS0 (moved from GPIO 12 to avoid conflict) |
| 19 | 35 | SPI1 MISO — volume oscillator input |

---

## Boot Configuration

`/boot/firmware/config.txt` active settings:

```
dtparam=i2c_arm=on
dtparam=spi=on
dtparam=spi_aux=on
dtparam=audio=on
dtoverlay=spi1-1cs,cs0_pin=16
dtoverlay=audremap,pins_12_13
force_turbo=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
arm_64bit=1
enable_uart=1
```

Note: SPI1 CS was moved from GPIO 12 to GPIO 16 to free GPIO 12 for PWM audio.

---

## ALSA Audio Configuration

`~/.asoundrc`:

```
defaults.pcm.card 1
defaults.ctl.card 1
```

Card 0 = vc4-hdmi (HDMI, not used)
Card 1 = bcm2835 Headphones (PWM audio via audremap overlay)

---

## Source Code Architecture

All source files are in `~/theremin/`. The project compiles with `make ultra` to produce the `umts` executable.

### File Map

| File | Role |
|------|------|
| `uts.c` | SPI oscillator sampling, calibration, thread management |
| `mtp.c` | Audio synthesis, ALSA output, theremin state machine (modes, settings, touch detection) |
| `wiringPiSPI.c` | Custom WiringPi SPI interface (bundled, not system library) |
| `wiringPiSPI.h` | Header for SPI interface |

### uts.c — Oscillator Sampling

**Key constants:**

```c
#define FASTCLK 200000000  // SPI peripheral base clock (200 MHz)
#define IF_MIN  3000       // minimum intermediate frequency offset
```

**Key globals:**

```c
volatile int rateP, rateV;           // SPI clock divisors per oscillator
volatile double pitch_if, vol_if;    // measured intermediate frequencies
```

**Startup sequence (main function, around line 187):**

```c
pitch_if = 570000;    // initial frequency guess for pitch oscillator
vol_if = 520000;      // initial frequency guess for volume oscillator
rateP = FASTCLK / pitch_if;   // BUG FIX: initialize before threads start
rateV = FASTCLK / vol_if;     // BUG FIX: initialize before threads start
pthread_create(&threadId, NULL, readOscs, (void*)0);  // pitch sampling thread
pthread_create(&threadId, NULL, readOscs, (void*)1);  // volume sampling thread
calibrate(pitch_if, vol_if);  // sweep to find actual oscillator frequencies
```

**readOscs thread (line ~65):**

- Continuously reads SPI data at the computed clock rate
- Measures the oscillator frequency by counting SPI bit transitions
- Updates `pitch_if` or `vol_if` globals
- Calls `wiringPiSPISetup()` repeatedly to adjust SPI clock speed

**calibrate function (line ~129):**

- Sweeps SPI clock through a range of divisors
- Looks for periodic signals in the SPI bit stream
- Reports found frequencies as "Osc 0 [rate] at [freq]" and "Osc 1 [rate] at [freq]"
- Typical results: Osc 0 ~564 kHz, Osc 1 ~513 kHz

**getIFs function (line ~120):**

```c
void getIFs(int* p, int* v) {
  *p = (int)pitch_if;
  *v = (int)vol_if;
}
```

Called by mtp.c to get current oscillator readings.

### mtp.c — Audio Synthesis and State Machine

**ALSA setup (line ~93):**

```c
snd_pcm_t *handle;
snd_pcm_open(&handle, "default", SND_PCM_STREAM_PLAYBACK, 0);
snd_pcm_set_params(handle, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
                    1, 44100, 1, 500000);
```

- 16-bit signed LE, interleaved, mono, 44100 Hz sample rate

**Main synthesis loop (line ~230+):**

- Calls `getIFs(&pitch_if, &vol_if)` to read current oscillator frequencies
- Computes pitch from: `tgtPitch = pitch*4096*pow((pitch_if-baseLineP)*1.0/tuning, pRange/50.0)/50`
- Computes volume from: `tgtVol = exp(-(vol_if-baseLineV)/250.0)*vol/100.0`
- Fills audio buffer with synthesized samples
- Writes to ALSA via `snd_pcm_writei(handle, buffer, sendSiz)`

**State machine / modes:**

- Touch detection via antenna proximity thresholds
- Multiple settings modes: tone, pitch range, volume, autotune, tuning
- Mode changes triggered by touching pitch/volume antennas simultaneously
- Currently announces mode changes via WAV files (to be replaced with LCD)

**Key variables for MIDI integration:**

```c
int currentTone;    // waveform type (sine, square, saw, etc.)
double tgtPitch;    // target pitch (frequency * scaling)
double tgtVol;      // target volume (0.0 to 1.0)
int pitch;          // pitch setting
int pRange;         // pitch range setting
int tuning;         // tuning reference
int autotune;       // autotune quantization level
```

### wiringPiSPI.c — SPI Interface

Custom bundled copy (not the system WiringPi library). Key functions:

- `wiringPiSPISetup(channel, speed)` — opens and configures an SPI device
- `wiringPiSPIDataRW(channel, data, len)` — reads/writes SPI data
- Opens `/dev/spidev0.0` (channel 0) and `/dev/spidev1.0` (channel 1)

---

## Code Changes Made (Bug Fixes)

### 1. Thread race condition fix (uts.c)

**Problem:** `rateP` and `rateV` were uninitialized (zero) when threads started, causing `FASTCLK/rate` to produce 0, which the SPI driver rejected with EINVAL.

**Fix:** Added initialization before `pthread_create` calls:

```c
rateP = FASTCLK / pitch_if;
rateV = FASTCLK / vol_if;
```

### 2. Rate=0 safety check (uts.c, line ~84)

**Problem:** If calibration fails to find an oscillator, rate stays at 0, causing divide-by-zero and SPI failure.

**Fix:** Added fallback before SPI setup:

```c
if (rate <= 0) {
  fprintf(stderr, "Channel %d: bad rate %d, using fallback\n", side, rate);
  rate = 350;  // safe fallback
}
```

### 3. Debug printf (wiringPiSPI.c, line ~121) — can be removed

Added before `SPI_IOC_WR_MAX_SPEED_HZ` ioctl:

```c
fprintf(stderr, "Setting SPI channel %d speed to %d Hz\n", channel, speed);
```

---

## Build

```bash
cd ~/theremin
make ultra
# produces: gcc -o umts uts.o mtp.o wiringPiSPI.o -lpthread -lasound -lm
```

Dependencies: ALSA dev libraries (`libasound2-dev`), pthreads, math library.

---

## Runtime

```bash
cd ~/theremin
./umts
```

**Important:** Do NOT run `gpiomon` on GPIO 9 or 19 before running `umts`. The `gpiomon` tool reconfigures pins as plain GPIO, taking them away from the SPI peripheral. If `gpiomon` was run, reboot before running `umts`.

**Typical successful startup output:**

```
P clock beat    loAlias hiAlias V clock beat    loAlias hiAlias
520833    7045  513788  527878  470588    8992  461596  479580
542005    6750  535255  548755  492610    9438  483172  502048
564971    7534  557437  572505  514138    9882  504256  524020
586510    8012  578498  594522  536193   10189  526004  546382
609756    8673  601083  618429  558659   10972  547687  569631
Osc 0 354 at 563689
Osc 1 389 at 513255
IFs: pitch 7768, vol 10069
```

---

## Where MIDI Would Hook In

MIDI output would integrate into `mtp.c`, in or alongside the existing audio synthesis loop.

**Available data per frame:**

- `tgtPitch` — the computed pitch value (frequency-derived)
- `tgtVol` — the computed volume (0.0–1.0 range, exponential decay from antenna distance)
- `pitch_if` / `vol_if` — raw intermediate frequencies from oscillators
- `baseLineP` / `baseLineV` — calibrated baseline frequencies (no hand present)
- `currentTone` — selected waveform/timbre
- `autotune` — quantization level (useful for snapping to MIDI note numbers)

**Suggested approach:**

- Add a MIDI output thread or integrate into the existing synthesis loop
- Convert `tgtPitch` to MIDI note number + pitch bend
- Map `tgtVol` to MIDI CC #7 (volume) or velocity
- Use ALSA MIDI sequencer API (`snd_seq_*`) for output, or write raw MIDI to a serial/USB device
- The `autotune` variable already quantizes pitch — this maps naturally to discrete MIDI notes

**ALSA MIDI would require:**

```c
#include <alsa/asoundlib.h>
snd_seq_t *seq_handle;
snd_seq_open(&seq_handle, "default", SND_SEQ_OPEN_OUTPUT, 0);
```

---

## Known Issues and Gotchas

1. **gpiomon conflicts with SPI** — never run gpiomon on GPIO 9/19 before umts; reboot if you did
2. **Pi Zero 2 W SPI1 speed limits** — SPI1 is pickier about clock speeds than SPI0; the code handles this via the rate initialization fix
3. **Antenna lead length matters** — long wires add capacitance, lowering oscillator frequency; keep leads between circuit and antenna short (a few inches)
4. **CD4069 oscillator sensitivity** — requires clean power (decoupling cap), good solder joints, and correct component values; a single wrong-value cap or missing feedback resistor will kill oscillation
5. **Audio output uses mono 44100 Hz S16_LE** — any MIDI implementation should not interfere with the existing ALSA PCM stream unless audio output is being replaced entirely
