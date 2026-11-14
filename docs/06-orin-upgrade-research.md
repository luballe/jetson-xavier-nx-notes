# Orin upgrade research (November 2026)

Notes on what moving from Xavier NX to the Orin generation would involve. Research only; nothing here was bought or tested. Prices were collected on 13 November 2026 and will go stale.

## Naming

There is no "Xavier Orin". Xavier and Orin are two generations, each with several sizes.

| Generation | Models | Software |
|---|---|---|
| Xavier (2018–2020) | AGX Xavier, Xavier NX | JetPack 5, end of the line |
| Orin (2022 onward) | AGX Orin, Orin NX, Orin Nano | JetPack 6 (Ubuntu 22.04, Python 3.10) |
| Thor (2025) | AGX Thor | JetPack 7 |

The direct successor to the Xavier NX is the **Orin NX** (8 or 16 GB): same module size, keeps the DLA and the hardware video encoder.

The **Orin Nano** is cheaper and runs the same current software, but has no hardware video encoder (NVENC) and no DLA.

## Modules versus developer kits

NVIDIA sells complete developer kits for only some models (Orin Nano, AGX Orin, Thor). The Orin NX is sold as a bare module, intended for a carrier board from someone else. NVIDIA does not sell its carrier boards separately.

Orin NX modules have no microSD slot and no onboard storage. They boot from NVMe.

## Can an Orin NX go on the Xavier NX developer-kit carrier (P3509)?

Physically yes. In software, only properly under JetPack 5.

| Point | Finding |
|---|---|
| Mechanical fit | The Orin NX module (P3767) fits the P3509 carrier. NVIDIA's FAQ calls the modules form-factor compatible but not pin-compatible: only the shared signals line up. |
| JetPack 5 | Supported. Jetson Linux 35.6.5 ships a board configuration `p3509-a02+p3767-0000` for exactly this pairing (confirmed in the downloaded BSP). |
| JetPack 6 | The configuration still exists, but an NVIDIA forum moderator says it is "not fully supported" on L4T 36.x and kept mainly so HDMI works; another says the Xavier NX carrier "is not supported on JetPack 6 anymore". |

Reports for JetPack 6 on this pairing:

- One user flashed 36.2 successfully after working around an installer bug (a USB device had to be attached during flashing).
- One user flashed 6.2 with the wrong configuration and got no network or video; NVIDIA pointed them at the `p3509` configuration and the thread has no confirmed outcome.
- No report was found confirming that USB, video, network and cameras all work under JetPack 6 on this carrier.

Forum users recommend carriers designed for Orin, which also expose an extra PCIe bus that the Xavier NX carrier cannot use.

Conclusion: an Orin NX on this carrier with JetPack 5 gives more speed but keeps Python 3.8, which removes most of the reason to upgrade. With JetPack 6 it is an unsupported experiment. Treat the old carrier as a way to try a module, not as the destination.

## Prices

NVIDIA raised prices across the Jetson line in July 2026, by 33 % to 101 %.

| Item | Before | After | Basis |
|---|---|---|---|
| Orin Nano Super Developer Kit | $249 | $399 | Single unit |
| Orin Nano 8 GB module | $299 | $399 | Per 1,000 units |
| Orin NX 8 GB module | $399 | $649 | Per 1,000 units |
| Orin NX 16 GB module | $599 | $999 | Per 1,000 units |
| AGX Orin Developer Kit | $1,999 | $3,499 | Single unit |
| Xavier NX module | $399 | $599 | Per 1,000 units |

Single-unit retail prices seen:

| Item | Price |
|---|---|
| Orin Nano Super Developer Kit | $399 (NVIDIA's store showed it out of stock); $449 as a Seeed bundle with power supply |
| Orin NX module, 8 GB to 16 GB | $799.99 to $1,199.99 (Waveshare publishes only the range) |
| Orin NX 16 GB module, eBay | About $600 to $1,200 |
| Seeed reComputer J401 carrier board | $111 to $190 depending on variant and seller |
| Waveshare Orin NX kits | $910.99 to $1,460.99 depending on memory and accessories |
| Seeed reComputer Super J4012 (Orin NX 16 GB, 128 GB SSD, case) | About $1,503 |

### Total cost by route

Estimates built from the single-unit prices above, not quotes.

| Route | With 8 GB | With 16 GB | Notes |
|---|---|---|---|
| Third-party assembled kit | From about $911 | About $1,500 | Nothing left over |
| Module + third-party carrier | About $910–$990 | About $1,310–$1,390 | Add a heatsink |
| Orin Nano kit + Orin NX module | About $1,200 | About $1,600 | The Orin Nano module is left over |
| Module only, on the existing P3509 carrier | About $800 | About $1,200 | JetPack 5 only in practice; add a heatsink |

Reading:

- Buying the Orin Nano kit just for its carrier is the most expensive route. It only makes sense as a staged path (use the Nano first, swap the module later) or if you already own the kit.
- The Orin Nano kit at $399 is the cheapest way into JetPack 6, without NVENC or DLA.

## Sources

- [Jetson Orin NX Series, Jetson Linux Developer Guide r35.2.1](https://docs.nvidia.com/jetson/archives/r35.2.1/DeveloperGuide/text/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxSeries.html)
- [Flashing Orin NX (p3509-a02-p3767-0000) not working in Jetson Linux 36.2](https://forums.developer.nvidia.com/t/flashing-orin-nx-io-base-b-p3509-a02-p3767-0000-not-working-in-jetson-linux-36-2/289450)
- [JetPack 6.2 fails to boot with Orin NX on Xavier NX developer kit](https://forums.developer.nvidia.com/t/jetpack-6-2-fails-to-boot-with-orin-nx-on-xavier-nx-developer-kit/321147)
- [Jetson Orin NX 16GB with Jetson Linux 35.4.1 on the Xavier NX developer kit](https://forums.developer.nvidia.com/t/jetson-orin-nx-16gb-with-jetson-linux-35-4-1-on-the-xavier-nx-developer-kit/302197)
- [Trying to decide between P3509-a02 board and P3768 board](https://forums.developer.nvidia.com/t/trying-to-decide-between-p3509-a02-board-and-p3768-board/311440)
- [Jetson FAQ](https://developer.nvidia.com/embedded/faq)
- [NVIDIA increases the price of Jetson modules and devkits by up to 101% (CNX Software)](https://www.cnx-software.com/2026/07/22/nvidia-increases-the-price-of-jetson-modules-and-devkits-by-up-to-101/)
- [Jetson Orin Nano Super Developer Kit (NVIDIA Marketplace)](https://marketplace.nvidia.com/en-us/enterprise/robotics-edge/jetson-orin-nano-super-developer-kit/)
- [Orin Nano Super Developer Kit bundle (Seeed Studio)](https://www.seeedstudio.com/NVIDIAr-Jetson-Orintm-Nano-Super-Developer-Kit-Bundle.html)
- [Jetson Orin NX module (Waveshare)](https://www.waveshare.com/jetson-orin-nx.htm)
- [Jetson Orin NX developer kit (Waveshare)](https://www.waveshare.com/jetson-orin-nx-16g-dev-kit.htm)
- [reComputer Super (Seeed Studio)](https://www.seeedstudio.com/reComputer-Super-Bundle.html)
- [reComputer J401 carrier board (Seeed Studio)](https://www.seeedstudio.com/reComputer-J401-Carrier-Board-for-Jetson-Orin-NX-Orin-Nano-without-Power-Adapter-p-5637.html)
