# FlashMD

A native macOS app for backing up and writing Sega Mega Drive / Genesis cartridges with a **FlashKit** or **MD Dumper**.

Scan a cartridge, inspect its game information, and back up its ROM, save data, or both. FlashMD suggests an export size from the cartridge contents and checks supported bank-switching protocols before reading banked games.

![FlashMD start screen](Screenshots/start.png)

## Features

- Automatic FlashKit and MD Dumper discovery.
- Cartridge title, region, product/revision code, header checksum and declared memory information.
- Editable display titles for cartridges with missing or misleading metadata.
- ROM content analysis with a suggested backup size and a complete-ROM option.
- Separate ROM and save exports, descriptive filenames and a JSON backup manifest.
- Backup verification enabled by default; mandatory for banked ROMs, serial saves and MD Dumper streaming.
- ROM programming and SRAM restoration on supported writable linear cartridges, with write verification.
- Read-only banked ROM backup using supported SSF2 and Pier Solar mapper protocols.
- Advanced cartridge configuration, SRAM formats, programmer selection and optional MD Dumper ROM streaming.
- Progress, transfer results and an activity history.

![Cartridge information and backup controls](Screenshots/backup.png)

## Requirements

- macOS 14 Sonoma or later.
- A compatible FlashKit or MD Dumper in Mega Drive mode.
- For building from source: Xcode with Swift 6 support.

MD Dumper hardware testing has used **firmware 2.0, board 3**. SRAM transfers, Pier Solar ROM backup, ROM writing and streaming currently require that configuration. Standard ROM backup is also available on other supported revisions.

## Before inserting or removing a cartridge

**Wait until any transfer has finished, then remove power before changing cartridges:**

- **MD Dumper:** turn the programmer **off** before inserting or removing a cartridge.
- **FlashKit:** **disconnect its USB cable** before inserting or removing a cartridge.

After inserting the cartridge, reconnect or turn on the programmer, then scan again. Closing FlashMD does not remove power from the device. Keep the cartridge seated and the programmer connected throughout scanning, backup and writing.

## Build and launch

The Xcode project is included in this repository; no Python client or separate dumper application is needed at runtime.

```sh
git clone https://github.com/mintho/FlashMD.git
cd FlashMD
open FlashMD.xcodeproj
```

Select the **FlashMD** scheme and **My Mac**, then run with **⌘R**. Configure a signing team in Xcode if required by your setup. The bundled core package is a local dependency.

For a command-line build without distribution signing:

```sh
xcodebuild -project FlashMD.xcodeproj -scheme FlashMD \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

This produces a local build, not a signed and notarized distribution package.

## Back up a cartridge

1. Insert the cartridge with the programmer powered off or disconnected, as described above.
2. Connect or turn on the programmer. Close other applications that might be using it.
3. Open FlashMD and click **Scan Cartridge**. Wait for identification and content analysis to finish.
4. In **Backup**, select **Game ROM**, **SRAM data**, or both. Click anywhere on a panel to change its selection. Serial save cartridges use a separate save label.
5. Leave the suggested ROM size selected, or enable **Back Up Complete ROM** to read the entire accessible range. **Details** explains the suggestion and any uncertain memory areas.
6. Click **Back Up…** and choose a destination. FlashMD creates a new folder for that backup.
7. Wait for completion. Use **Show in Finder** to open the folder, or **New Transfer** to return to the controls.

The suggested size combines the game header with an analysis of the cartridge contents, including data beyond an incorrect header. Use **Details** to review it, or **Back Up Complete ROM** to include the full accessible range. Special cartridge hardware is covered below under **Cartridge compatibility**.

FlashMD detects SRAM from the header and checks the memory before offering a save backup. If save memory is missing or incorrectly declared, inspect **SAVE MEMORY** and **Game Details**; a manual SRAM layout is available in Advanced Settings.

## Backup files and save formats

A backup can contain:

| File | Contents |
| --- | --- |
| `.bin` | Raw, big-endian game ROM. |
| `.srm` | Separate cartridge save data in the selected export format. |
| `manifest.json` | Cartridge and reader information, memory layout, file sizes, SHA-256 hashes, verification results and limitations. |

Filenames use the game title, declared regions such as `(JP, US, EU)`, and `[rev N]` when a recognized nonzero revision code is present. The backup folder also includes a timestamp and unique identifier. Revision tags reflect the header code, not a verified retail version history.

ROM and save data are separate files, even when backed up together. A `.srm` file contains cartridge save memory; it is **not an emulator save state**. Emulator and flash-cart save conventions vary, so check the destination's required format and filename.

**SRAM export format** in Advanced Settings offers:

- **Save bytes only** — the default. Exports the active save bytes without unused bus bytes. Usually the useful starting point for transferring saves to an emulator or flash cart.
- **Full bus dump** — includes both byte lanes. For single-lane SRAM, this is twice the size of the save bytes. Useful when another tool expects an interleaved dump or when preserving the bus representation. MD Dumper fills unused even-lane bytes with zero.

**SRAM input format** defaults to **Automatic**. FlashMD compares the file size with the configured SRAM layout and accepts an unambiguous match. Select a format manually if necessary; file extensions alone do not identify the format.

Pier Solar's supported SPI save export uses save bytes only and preserves the full 64 KiB serial address range. Repeated data is retained; this range is not a claim about the physical chip capacity.

## Write a cartridge

Use a supported **writable flash cartridge**. Ordinary ROM cartridges cannot be rewritten.

1. Scan the target cartridge, then select **Write**.
2. Select **Game ROM** and/or **SRAM data**, then choose the corresponding files.
3. Check the available capacity and selected operations.
4. Click **Write…**, review the changes and confirm with **Write ROM**, **Write Saves** or **Write Both**.
5. Keep the programmer connected until writing and verification finish.

Writing replaces the selected cartridge contents and cannot be undone without an existing backup. Make a backup first if you need to keep them. Selecting only ROM is intended to preserve existing SRAM on supported configurations; recovery files may be created while preserving saves during a write.

**Clear unused ROM space** is enabled by default. It erases cartridge ROM beyond the new game's end within the supported write range. It does not modify the source file on your Mac. MD Dumper's supported ROM-writing procedure erases the whole flash chip, so unused ROM cannot be retained there.

For MD Dumper, **Prepare ROM Writing…** identifies the flash chip separately from normal scanning. Follow the restart instructions with the same cartridge still inserted, then scan again. FlashMD checks the cartridge before enabling writing. If the reader needs a power cycle or cleanup fails, stop and follow the displayed instructions.

## Cartridge compatibility

FlashMD supports standard Mega Drive / Genesis ROM cartridges and SRAM saves with both programmers. It also backs up larger games using SSF2-style or Pier Solar bank switching. Scanning sets up the cartridge automatically and checks which operations are available.

| Cartridge / operation | FlashKit | MD Dumper |
| --- | --- | --- |
| Standard ROM backup | Yes | Yes |
| Standard SRAM backup | Yes | Yes |
| ROM writing to compatible linear flash cartridges | Yes | Yes — preparation and restart required |
| SRAM restoration on compatible linear cartridges | Yes | Yes |
| SSF2-style banked ROM backup | Yes | Yes |
| SSF2-style banked SRAM backup | — | Yes |
| Pier Solar ROM backup | Yes | Yes |
| Pier Solar SPI save backup | Yes | — |

**Bank switching:** FlashMD checks the cartridge's response during scanning rather than relying on its title alone. Reader hardware can make a difference: Demons of Asteborg was successfully backed up with MD Dumper, while the tested FlashKit could not switch its banks.

**Save memory:** SRAM backup and restoration depend on the detected memory layout. MD Dumper supports odd-lane SRAM, the common layout that stores one save byte per bus word. FlashMD offers restoration when write access is supported; some detected layouts are available for backup only. Banked SRAM backup requires a successful memory check.

**Special hardware:** The dashes mark save operations currently unavailable on that reader. EEPROM and other custom save protocols, plus banked ROM and banked save writing, are not implemented yet. ROM and save backups do not include separate storage for cartridge hardware such as additional audio chips.

### Read verification and streaming

Backup verification compares independent reads to check the exported files. During scanning, FlashMD can automatically repeat a ROM read comparison failure up to three complete attempts. Persistent errors are reported, and cartridge programming is never automatically retried. These checks establish read consistency; they cannot prove that every part of an unknown cartridge design has been captured.

**MD Dumper ROM streaming** is an optional setting that uses larger transfers, with independent verification. The speed gain depends on the cartridge. Changes take effect on the next scan or backup.

## Troubleshooting and reporting issues

- **No programmer found:** check the USB connection, power switch and Mega Drive mode. Close other dumper applications, then scan again.
- **Unreadable header:** follow the restart instructions with the cartridge still inserted. Do not prepare ROM writing merely to troubleshoot a retail cartridge.
- **Verification failed:** do not treat the operation as successful. Check Activity, restart the reader as instructed and scan again.
- **Incorrect game title:** use the pencil beside the title. This changes FlashMD's display/export name, not the cartridge header.

When [reporting an issue](https://github.com/mintho/FlashMD/issues), include the macOS version, programmer model/firmware, cartridge edition, operation, exact error and relevant Activity details. If available, include the backup manifest after removing personal paths. Do not attach game ROMs or personal save files.

## Development

Run the software tests:

```sh
swift test --package-path Packages/FlashMDCore
```

Hardware tests are opt-in and skipped by default. The app includes **Cartridge → Demo Mode** for exploring the interface without accessing cartridge contents; transfers are disabled in that mode.

## License and credits

FlashMD is licensed under the **GNU General Public License, version 3**. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Distributed binaries must be accompanied by access to their corresponding source under the license terms.

Protocol and command-sequence references include:

- [Krikzz FlashKit](https://github.com/krikzz/flashkit) — GPLv3.
- [Joey Parrish's FlashKit MD Python client](https://github.com/joeyparrish/flashkit-md-py) — GPLv3.
- [X-death25's MD Dumper software](https://github.com/X-death25/MD_Dumper) — GPLv3.

FlashMD uses native Swift, POSIX serial access and Apple's IOKit USB APIs. It does not bundle the reference clients, cartridge firmware, game ROMs or BIOS files. FlashMD is not affiliated with Sega or the programmer manufacturers.
