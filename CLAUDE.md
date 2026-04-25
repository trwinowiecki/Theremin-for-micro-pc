# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A full-featured digital Theremin implementation for Raspberry Pi that transforms simple hardware (a single CMOS IC and passive components) into a complete musical instrument with pitch and volume antennae control. See https://www.simulistics.com/theremin.html for complete project details.

## Build Commands

### Standard Build (uses pigpio library)
```bash
make          # Builds mts executable and voice files
make install  # Installs to /usr/local/bin with proper permissions
```

### Ultra-Minimal Build (uses SPI controllers, no external latches)
```bash
make ultra         # Builds umts executable and voice files
make install_ultra # Installs umts as /usr/local/bin/mts
```

### Dependencies
- Standard build: `libasound2-dev`, `pigpio`
- Ultra build: `libasound2-dev` only

## Architecture

The codebase is split into two main subsystems that run in separate execution contexts:

### Sensing Subsystem (mts.c or uts.c)
Handles real-time frequency detection from oscillator circuits connected to GPIO pins:
- **mts.c**: Uses pigpio library for GPIO edge detection via hardware interrupts
  - Monitors two sensor pins (SENS_P=GPIO10 for pitch, SENS_V=GPIO27 for volume)
  - Generates reference clocks on REF_P=GPIO4 and REF_V=GPIO6
  - Detects beat frequencies (IF_MIN to IF_MAX range: 3-25kHz)
  - Auto-calibrates by scanning oscillator frequencies and finding valid beat ranges

- **uts.c**: Ultra-minimal replacement using SPI controllers instead of pigpio
  - Reads oscillator state via two SPI interfaces (spidev0.0 and spidev1.0)
  - Eliminates need for external latch hardware by directly sampling SPI data
  - Uses modified wiringPiSPI.c to address different SPI controllers as separate interfaces rather than chip selects
  - Runs two reader threads (readOscs) that continuously sample oscillators via SPI buffers
  - Calculates frequencies by finding bit transitions in SPI data streams

Both implementations:
- Export getIFs() to retrieve current intermediate frequencies (beat frequencies from pitch/volume sensors)
- Export getTSs() to provide timestamps of last sensor updates
- Use exponential smoothing (TIMECONST=0.04) for frequency stability
- Handle calibration to auto-discover oscillator frequencies within UNCERTAINTY (±50kHz)

### Playing Subsystem (mtp.c)
Audio synthesis and user interface, linked with either sensing module:
- Generates 44.1kHz audio output via ALSA
- Waits for sensor updates before generating samples (reduces latency, eliminates pitch "flats")
- Implements state machine for configuration modes:
  - PLAY: Normal theremin operation
  - STANDBY: Touch both antennae to enter setup
  - SET_PITCH, SET_SLOPE_P, SET_VOL, SET_TONE: Configuration states
  - AUTOTUNE, TUNING: Musical scale and reference pitch settings
- Supports multiple waveforms (SINE, CLASSIC, VALVE, TRIANGLE, SAWTOOTH, SQUARE)
- Autotune modes: CONTINUOUS, CHROMATIC, MAJOR, BLACK (pentatonic), FLOYDIAN, ARPEGGIO, AEOLIAN
- Touch detection via TOUCHED threshold (IF > 12kHz indicates antenna touch)
- Voice feedback from .wav files in /usr/local/lib/mts/

## Key Technical Details

### Frequency Measurement Approach
Both implementations measure beat frequencies between reference oscillators (driven by Pi) and sensor oscillators (affected by hand proximity to antennae). The difference creates an audible/measurable intermediate frequency (IF) that indicates hand distance.

### Latency Reduction
mtp.c waits for sensor timestamp updates (getTSs) before generating audio, ensuring fresh sensor data and smooth pitch sweeps without flat spots during fast gestures.

### wiringPiSPI.c Modification
The only change from Gordon Henderson's original: channel parameter selects SPI interface (/dev/spidev0.0 vs /dev/spidev1.0) rather than chip select, enabling simultaneous dual oscillator monitoring.

## Build Artifacts
- Voice files: autotune.wav, prange.wav, standby.wav, tuning.wav, play.wav, pslope.wav, tone.wav, vrange.wav
- Executables: mts (standard) or umts (ultra-minimal)
