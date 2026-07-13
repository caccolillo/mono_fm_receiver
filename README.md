# AM64x Industrial Communication Kit ↔ Artix-7 FPGA: High-Speed Link Feasibility & Path to Production

## Summary

Investigation into connecting the Phytec phyCORE-AM64x Industrial Communication Kit to a low-cost Xilinx Artix-7 FPGA board for evaluation purposes, with the eventual aim of a cost-optimised production platform. Covers interface compatibility analysis (PCIe, GT/Aurora, USB, and other options), a comparison of viable high-speed links, recommended hardware for fast evaluation, and a production migration plan reusing the same processor and a low-cost Artix-7 device.

---

## 1. Background / Goal

- **Host platform**: [phyCORE-AM64x Industrial Communication Kit](https://www.phytec.eu/en/produkte/development-kits/phycore-am64x-industrial-communication-kit/) — TI AM64x SoC (Cortex-A53 x2 @ 1 GHz, Cortex-R5F x4 @ 800 MHz, Cortex-M4F @ 400 MHz), Linux (Yocto-based) BSP with PHYTEC BSP + IBV real-time Ethernet extensions (EtherCAT, PROFINET, EtherNet/IP).
- **Target FPGA (initial candidate)**: [ALINX AX7103](https://www.en.alinx.com/Product/FPGA-Development-Boards/Artix-7/AX7103.html) — Xilinx Artix-7 XC7A100T, PCIe Gen2 x4 edge connector, 2x GbE, 2x HDMI, 1 GB DDR3, ~$277.
- **Goal**: establish the fastest possible high-speed data link between the two boards for early-stage evaluation (budget for this phase is flexible), with a longer-term requirement to migrate to a **low-cost production design** using the **same processor (AM64x)** and a **low-cost Artix-7 device**.

---

## 2. Interface Inventory

### phyCORE-AM64x Industrial Communication Kit — relevant interfaces
| Interface | Detail |
|---|---|
| Ethernet | 3x 10/100/1000BASE-T, TSN support |
| USB | 1x USB 2.0, 2x USB 3.0 |
| Serial | 1x RS-232/RS-485, up to 3x UART (expansion), 1x FSI |
| CAN | 2x CAN-FD |
| **PCIe** | **1x PCIe 2.0, 1-lane, exposed via Mini PCIe connector** |
| Expansion Bus | SPI, UART, I²C, USB, ADC |
| Debug | JTAG header, XDS110 |
| FPGA fabric | **None** — AM64x is a fixed-function SoC, no programmable logic on this variant |

Note: a separate **phyCORE-AM64x FPGA** variant exists with a companion **Lattice ECP5** device (4x Ethernet interfaces, for time-critical tasks), but this is a different kit from the Industrial Communication Kit under evaluation and was not pursued further here.

### ALINX AX7103 — relevant interfaces
| Interface | Detail |
|---|---|
| FPGA | Xilinx Artix-7 XC7A100T |
| **PCIe** | **1x PCIe Gen2 x4, standard full-size edge-finger connector** (card is designed as a PCIe *endpoint*, meant to plug into a PC/host PCIe slot — it does not itself provide a slot to host other cards) |
| Ethernet | 2x Gigabit Ethernet |
| Video | 2x HDMI (1 in / 1 out) |
| Memory | 1 GB (32-bit) DDR3, 16 MB QSPI Flash |
| Expansion | 2x 40-pin (2.54 mm) expansion ports, 34 IOs |
| Power | Independent 12 V / 2 A supply (not slot-powered) |

---

## 3. Core Compatibility Problem: PCIe

The two PCIe interfaces are **mechanically and electrically mismatched**:

- Phytec side: **Mini PCIe socket** — host-side (root complex) connector, physically a laptop/embedded-style socket for Mini PCIe cards (WiFi/LTE modems, mSATA, etc.), electrically fixed at **1 lane**.
- AX7103 side: **full-size PCIe x4 edge connector** — designed to be *inserted into* a host slot, not to receive one.

These connectors cannot be wired directly together. To make the link work at all requires:

1. **A physical adapter/riser**: Mini PCIe (host socket) → PCIe x1 riser cable, of the type used in mining rigs / laptop eGPU mods. Must be rated for PCIe Gen2 (5 GT/s) signalling; cheap ribbon-style risers risk marginal signal integrity at Gen2 speeds — keep cable length short.
2. **Lane width reconfiguration**: the AX7103's Xilinx 7-Series Integrated Block for PCI Express must be regenerated for a **Gen2 x1** link (not x4), even though its physical connector is wired x4. PCIe supports link training down to a subset of lanes, so only lane 0 + REFCLK/PERST#/WAKE# need to be connected through the riser.
3. **Root complex / endpoint direction check**: the Mini PCIe socket implies AM64x's (Cadence-based) PCIe controller is configured as **root complex** by the kit's default BSP — consistent with the AX7103 acting as **endpoint** (the normal config for this class of accelerator board). Direction-wise this should line up, but confirm in the AM64x kit's reference manual/BSP release notes and device tree rather than assuming, since AM64x's PCIe controller can be strapped either way.
4. **Power**: not a real constraint — the AX7103 takes its own 12 V/2 A supply directly, so the riser only needs to carry signalling, not deliver slot power (unlike passive PCIe x1 risers used for actual GPUs, which do need to source card power).
5. **Software stack**: AXI-PCIe bridge or Xilinx XDMA IP in the Artix-7 fabric with BAR-mapped registers/DMA; corresponding Linux PCIe driver (or UIO/VFIO) on the AM64x/Yocto side.

**Risk summary**: doable, but the weakest link is Gen2 signal integrity across a generic Mini PCIe riser cable — this is the part most likely to cause instability (failed link training) rather than any architectural issue.

---

## 4. Other High-Speed Interface Options Considered

### 4.1 GT / Aurora — **not feasible**
Aurora requires Xilinx GTP/GTX/GTH SerDes transceivers plus custom PHY framing on **both** ends. The AM64x SoC has **no FPGA fabric and no general-purpose SerDes** — its high-speed lanes are fixed-function, hard-wired to specific controllers (PCIe, USB3, SGMII). There is no way to repurpose those lanes for an arbitrary serial protocol like Aurora. The AM64x kit's expansion connector only exposes SPI/UART/I²C/USB/ADC at the pin level — no raw differential pairs are broken out for a custom high-speed PHY. This is a board/kit constraint, not an Artix-7 limitation (the Artix-7 is fully capable of SelectIO-based fast serial links or GT-based Aurora — it just has no partner interface on the AM64x side).

The phyCORE-AM64x **FPGA** variant (Lattice ECP5) does have real fabric, but ECP5 doesn't run Xilinx's proprietary Aurora IP — a custom SerDes protocol would need to be implemented on both the ECP5 and the Artix-7, which is a project in its own right, and it's a different kit from the one being evaluated.

### 4.2 Gigabit Ethernet — **best effort-to-throughput ratio**
3x GbE with TSN support already on the AM64x side. Implementation: AXI Ethernet MAC + soft core (MicroBlaze/PicoBlaze) or a hardened MAC-to-PL bridge on the Artix-7 side; lwIP or raw frames to skip IP-stack overhead. Realistic throughput: **~800–900 Mbps** with a decent DMA/frame pipeline. No adapters, no lane-config, no signal-integrity risk — plug two RJ45s together (or via a switch) and go. Also plays directly to the kit's TSN/real-time Ethernet strengths.

### 4.3 PCIe Gen2 x1 (via Mini PCIe riser) — see Section 3
Theoretical ~400–500 MB/s, realistic ~200–350 MB/s depending on DMA engine and riser quality. More raw bandwidth than GbE, more fragile physical layer.

### 4.4 USB 3.0 — **viable middle ground, needs a bridge chip**
AM64x has 2x USB 3.0 host ports; AX7103 has **no USB PHY** connected to fabric (only USB-to-UART for console). Requires an external USB3 FIFO bridge chip — **Cypress/Infineon FX3** or **FTDI FT600/FT601** — which terminates SuperSpeed signalling itself and exposes a synchronous parallel FIFO (16/32-bit, up to ~100 MHz, recommend underclocking to 50–66 MHz over header wiring for margin) to the FPGA fabric via the AX7103's 40-pin expansion port.
- Realistic throughput: **~200–350 MB/s** sustained.
- Requires: an off-the-shelf FT601/FX3 breakout board (or custom carrier), a simple synchronous FIFO controller in fabric, and libusb/FTDI D3XX driver on the AM64x/Linux side (simpler driver story than a PCIe endpoint).
- More robust signal integrity than a PCIe Gen2 riser, since the FIFO interface tolerates header/jumper-wire connections much better than SerDes.

### 4.5 Multi-lane QSPI — low effort, low throughput
AM64x expansion bus SPI, run as master against a custom SPI-slave core in Artix-7 fabric. Realistic **~40–80 MB/s** with QSPI-style 4-bit-wide transfers at fast clock rates. Simple to bring up, but well below GbE/USB3/PCIe — only useful where simplicity matters more than bandwidth.

### 4.6 PRU-driven custom parallel GPIO bus — deterministic, not high-bandwidth
AM64x PRU-ICSS(G) units can bit-bang a parallel data bus + strobe/clock to the Artix-7's expansion header, captured by a matching FPGA state machine. Realistic **~100–300 Mbps** depending on GPIO count and PRU loop timing. Firmware-heavy (hand-timed PRU assembly/C). Only worth it for deterministic low-latency framing rather than raw throughput — could matter for a hard real-time application given the kit's industrial-comms focus.

### Comparison table

| Option | Effort | Throughput | Fragility |
|---|---|---|---|
| Gigabit Ethernet | Lowest (already wired) | ~800–900 Mbps | Very low |
| USB3 (FT601/FX3 bridge) | Medium (new bridge board + FIFO core) | ~200–350 MB/s | Low–medium |
| PCIe x1 (Mini PCIe riser) | Medium–high (riser + XDMA + RC/EP config) | ~200–400 MB/s | Medium (Gen2 link training over an adapter) |
| Multi-lane SPI | Low | ~40–80 MB/s | Very low |
| PRU parallel GPIO bus | Medium–high (firmware-heavy) | ~100–300 Mbps | Low, but latency/timing-sensitive |

---

## 5. Alternative Hardware to Ease the PCIe Connection

Rather than fighting the Mini PCIe ↔ full-size PCIe mismatch with a generic riser, several purpose-built options exist:

### 5.1 Native Mini PCIe-format Artix-7 board — **no adapter needed**
**Acromag AcroPack APA7-500** — a Xilinx Artix-7 module built directly in the Mini PCIe mechanical form factor (70 mm x 30 mm, standard mPCIe mounting/standoffs). Plugs straight into the Phytec kit's Mini PCIe socket.
- FPGA: **XC7A50T** (52,160 logic cells configuration) — a genuinely low-cost Artix-7 part.
- PCIe: **1-lane Gen1** interface with 1 DMA channel (Gen1, not Gen2 — a Gen2 host trains down to Gen1 automatically; roughly half the per-lane bandwidth of Gen2 x1, still likely sufficient for early evaluation).
- Ships with an **Engineering Design Kit (APA7-EDK)**: schematics, example VHDL, and a working Vivado IP Integrator project for the PCIe link, DMA, and register interface — validate application logic behind an already-proven endpoint core rather than writing one from scratch.
- Field-reconfigurable via flash download over PCIe.
- COTS/defense-channel pricing (higher than the AX7103) and potentially longer factory lead time direct from Acromag — check distributor stock (ArtisanTG, Systerra, Arms.com) if lead time matters.

### 5.2 M.2-format Artix-7 boards + M.2-to-Mini-PCIe adapter — cheaper, community-proven
- **PicoEVB** — Xilinx Artix-7, ~$219, explicitly documented to work via an M.2-to-Mini-PCI-Express adapter.
- **Numato Aller** — Artix-7 100T (~101K LUTs, 600 KiB BRAM, 240 DSP), M.2 M-key x4 PCIe Gen2, also usable via an M.2-to-PCI-Express adapter without loss of functionality.

Both are purpose-built for exactly this "prototype PCIe FPGA outside a desktop tower" use case; the M.2-to-mPCIe adapter path is well-trodden in the laptop-eGPU/FPGA hobbyist community. Bandwidth is still capped by the Phytec side's single lane regardless of which board is used, since that's a host-socket limit.

### 5.3 "PCIe rack" / powered dock option
Powered eGPU-style docks (e.g. ADT-Link, EXP GDC) take a Mini PCIe or M.2 input and break it out to a full PCIe slot, but — unlike a bare ribbon riser — include their own power delivery and often signal re-driver/re-timer circuitry. ADT-Link's mPCIe-to-PCIe x1 adapters are rated for Gen3 (8 Gbps) signalling on short cables, giving materially better signal integrity margin at Gen2 speeds than a generic mining riser. Relevant if committed to keeping a full-size card like the AX7103 rather than switching to a native mPCIe/M.2 board.

---

## 6. Recommendation

### 6.1 Evaluation phase (speed prioritised, budget flexible)
**Use the Acromag APA7-500.** It plugs directly into the Phytec kit's Mini PCIe socket with zero adapter/riser risk, ships with a working PCIe + DMA reference design (APA7-EDK), and lets us validate the data path and driver stack immediately without any physical-layer debugging. Source through a distributor (ArtisanTG / Systerra / Arms.com) to check stock and avoid Acromag's direct-order lead time if that's a concern.

### 6.2 Production phase (low-cost Artix-7 + same processor)
Migrate the validated architecture to a custom board:
- **Processor**: AM64x directly (same SoC as the eval kit, not the Phytec carrier board) — the "same CPU as the eval board" requirement is satisfied by design, since the eval and production processor are identical.
- **FPGA**: carry forward the **XC7A50T** validated in the APA7-500 eval (or step down further to XC7A35T/XC7A25T if post-eval utilisation numbers allow — Artix-7's cost/density scaling is roughly linear, so check bitstream utilisation before committing to a smaller device).
- **Connector removal**: route PCIe diff pairs directly between AM64x and Artix-7 on the custom PCB — no Mini PCIe mechanical connector needed, removing an insertion-loss/reflection point and a BOM line.
- **Possible lane-count upside**: the Phytec kit's 1-lane limit is a property of *that carrier board's* Mini PCIe breakout, not necessarily a hard limit of AM64x's PCIe controller. **Action item: check the AM64x TRM's PCIe0 subsystem for max supported lane count in root-complex mode** — if 2 lanes are natively supported, a custom board could route both lanes to the Artix-7 for roughly double the throughput validated in eval, at no extra component cost.
- **RTL/driver reuse**: the PCIe endpoint core, DMA engine, and Linux driver stack proven against the APA7-500's reference design carry over directly to a bare-die Artix-7 production design (same silicon family, same hard IP block) — this becomes a re-target/re-constrain exercise, not a rewrite.

---

## 7. Open Action Items
- [ ] Confirm AM64x kit's default BSP configures the Mini PCIe-attached PCIe controller as **root complex** (check reference manual / device tree / BSP release notes).
- [ ] Order APA7-500 + APA7-EDK (check distributor stock for lead time).
- [ ] Validate Gen1 x1 PCIe link + DMA reference design from APA7-EDK against AM64x Linux PCIe driver.
- [ ] Check AM64x TRM for native PCIe0 subsystem max lane count (root-complex mode) — informs production board lane-count decision.
- [ ] Post-eval: capture Artix-7 XC7A50T bitstream utilisation to decide whether XC7A35T/XC7A25T is viable for production cost reduction.
- [ ] Draft production board PCIe layout: AM64x ↔ Artix-7 direct diff-pair routing (no Mini PCIe connector).
