# Display EDID Tool for Intel Hackintosh

Rename a display on an Intel Hackintosh: patch the monitor name inside its EDID and update the matching display override file in one run.
Fixes "Unknown Display" in System Settings, Color Profile and Hackintool, and works alongside One-Key HiDPI.

---

<img width="850" height="431" alt="Display-EDID-Tool-SS" src="https://github.com/user-attachments/assets/aae104cb-f8e8-48bc-bd41-75c91e9681fe" />

## What it does

1. Lists every connected display with its **Vendor ID, Product ID, EDID name, physical size, native mode, checksum and raw EDID**.
2. You choose a display and enter the new name (for example `Color LCD`).
3. The tool:
   - patches the monitor-name field in the EDID and fixes the checksum (extension blocks are left untouched),
   - prints the new EDID for your OpenCore config,
   - patches the display override in `/Library/Displays/Contents/Resources/Overrides/` with the same name, creating a minimal one if none exists,
   - renames the EDID embedded in the override as well, if One-Key HiDPI put one there.
4. The script then exits.

## Requirements

- Intel Hackintosh running macOS
- Nothing to install: it only uses tools that ship with macOS (`ioreg`, `plutil`, `xxd`, `base64`, `awk`, `sed`)
- Works with the stock macOS bash (3.2)

## Usage

Download the release zip, unzip it in Finder, then double-click `display-edid-tool.command`, or run it from Terminal:

```bash
chmod +x display-edid-tool.sh
./display-edid-tool.sh
```

Example session:

```
If you use One-Key HiDPI, run this script after it, not before.
Re-running One-Key HiDPI overwrites the override and loses the name.

(1)
    EDID name     : <none>
    Maker code    : LGD
    Vendor ID     : 12516 (0x30e4)
    Product ID    : 1601 (0x641)
    Physical size : 31 x 17 cm (about 14.2 inch)
    Native mode   : 1920x1080
    ...

Choose the display [1~2, or p to paste an EDID]: 1

Your monitor VID:PID: 30e4:0641

(1) Rename a display
(2) Quit

Enter your choice [1~2]: 1
Enter the new display name (max 13 characters) [Color LCD]:
```

## Adding the EDID to OpenCore (built-in screen only)

When you answer **y** to "Is this the laptop's BUILT-IN screen?", the tool prints these steps:

1. Open `EFI/OC/config.plist`.
2. Go to `DeviceProperties -> Add ->` your iGPU path, usually `PciRoot(0x0)/Pci(0x2,0x0)`.
3. Add `AAPL00,override-no-connect`, type **Data**, and paste the new EDID the tool printed.
4. Replace any older value for that key instead of adding a second one, then reboot.

Back up your EFI before editing it.

## Important notes

- **Only inject the built-in panel's EDID in OpenCore.** An external monitor's EDID on the internal connector can give a wrong resolution or a black screen. For external monitors the override file alone is enough. The tool lists size and native mode so you can tell them apart.
- **Run it after One-Key HiDPI, not before.** Re-running One-Key HiDPI overwrites the override and the name is lost.
- **Names are limited to 13 plain-ASCII characters.** That is an EDID limit.
- The EDID name and the override name are always set from the same input, so they match.
- If the EDID has no free descriptor slot, the tool uses the serial-number slot as a last resort and warns you. If nothing is free, it stops and changes nothing.
- Backups of an existing override are saved to `~/display-override-backups/`.
- If the EDID embedded in an override can't be renamed in place, the tool tells you why and offers to replace it with the new patched EDID.

## Troubleshooting

**"could not be executed because you do not have appropriate access privileges"**
Downloads lose the executable bit. Run `chmod +x display-edid-tool.command display-edid-tool.sh`, or use the zip from the releases page, which keeps it.

**"Cannot be opened because it is from an unidentified developer"**
Approve it in System Settings -> Privacy & Security, or run `xattr -d com.apple.quarantine display-edid-tool.command`.

**The old name still shows after a reboot**
- Remove stale profiles in `~/Library/ColorSync/Profiles/Displays/` and `/Library/ColorSync/Profiles/Displays/`.
- Delete `/Library/Preferences/com.apple.windowserver*.plist`.
- Reboot again.

**No displays found**
The tool reads EDIDs from `ioreg`. Choose `p` at the prompt and paste an EDID from Hackintool instead.

## Limitations

- Intel Hackintosh only. Apple Silicon isn't supported.
- It renames displays. It doesn't generate HiDPI resolutions, so use One-Key HiDPI for that.

## Note
Developed and used on a Dell Latitude 7410 with the help of Claude. Other machines should work the same way, but they haven't been tested.
