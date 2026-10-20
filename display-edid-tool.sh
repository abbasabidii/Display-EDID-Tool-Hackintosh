#!/bin/bash
#
# display-edid-tool.sh
#
# Flow (one run, then the script ends - same style as One-Key HiDPI):
#   1. Lists every connected display with Vendor ID, Product ID and EDID
#   2. You choose a display
#   3. You enter a new display name
#   4. The EDID name is patched, the new EDID is printed, and the display
#      override file is patched with the same name
#
# For Intel Hackintosh. Works with the stock macOS bash (3.2) and needs only
# tools that ship with macOS (ioreg, plutil, xxd, base64, awk, sed).
#
# Run:  chmod +x display-edid-tool.sh && ./display-edid-tool.sh

LC_ALL=C
export LC_ALL

OVR_BASE="${OVR_BASE:-/Library/Displays/Contents/Resources/Overrides}"
BACKUP_DIR="$HOME/display-override-backups"

if [ -t 1 ]; then
    BLD=$'\033[1m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
else
    BLD=""; GRN=""; YEL=""; RED=""; RST=""
fi

ok()   { printf '%s%s%s\n' "$GRN" "$*" "$RST"; }
warn() { printf '%s! %s%s\n' "$YEL" "$*" "$RST" >&2; }
err()  { printf '%sx %s%s\n' "$RED" "$*" "$RST" >&2; }
die()  { err "$*"; exit 1; }

LINE="------------------------------------------------------------"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# byte HEX INDEX -> decimal value of that byte
byte() { echo $((16#${1:$(($2 * 2)):2})); }

# chr N -> the ASCII character with code N
chr() { printf "\\$(printf '%03o' "$1")"; }

# hex_to_b64 HEX -> base64 on one line
hex_to_b64() { printf '%s' "$1" | xxd -r -p | base64 | tr -d '\n'; }

# Accepts raw hex, "0x.. 0x..", or a whole ioreg line: "IODisplayEDID" = <...>
clean_hex() {
    local s="$1"
    case "$s" in
    *"<"*)
        s="${s#*<}"
        s="${s%%>*}"
        ;;
    esac
    s=$(printf '%s' "$s" | tr -d ' \t\r\n' | tr 'A-FX' 'a-fx')
    s="${s//0x/}"
    printf '%s' "$s"
}

# validate_edid HEX -> 0 if usable; otherwise 1 and the reason is left in $VERR
VERR=""
validate_edid() {
    local h="$1"
    VERR=""
    if ! [[ "$h" =~ ^[0-9a-f]+$ ]]; then
        VERR="that is not a hex string"
        return 1
    fi
    if ((${#h} % 2 != 0)); then
        VERR="odd number of hex digits (part of the EDID was probably clipped)"
        return 1
    fi
    if ((${#h} < 256)); then
        VERR="it is only $((${#h} / 2)) bytes long; an EDID is at least 128 bytes"
        return 1
    fi
    if [ "${h:0:16}" != "00ffffffffffff00" ]; then
        VERR="it does not start with the EDID header 00ffffffffffff00"
        return 1
    fi
    return 0
}

# checksum_ok HEX -> success when the first 128 bytes sum to 0 mod 256
checksum_ok() {
    local h="$1" sum=0 i
    for ((i = 0; i < 128; i++)); do
        sum=$((sum + 16#${h:$((i * 2)):2}))
    done
    ((sum % 256 == 0))
}

# fix_checksum HEX -> prints HEX with byte 127 recomputed
fix_checksum() {
    local h="$1" sum=0 i cs
    for ((i = 0; i < 127; i++)); do
        sum=$((sum + 16#${h:$((i * 2)):2}))
    done
    cs=$(((256 - (sum % 256)) % 256))
    printf '%s%02x%s' "${h:0:254}" "$cs" "${h:256}"
}

# ---------------------------------------------------------------------------
# EDID decoding
# ---------------------------------------------------------------------------

edid_vid() { echo $(((16#${1:16:2} << 8) | 16#${1:18:2})); }
edid_pid() { echo $(((16#${1:22:2} << 8) | 16#${1:20:2})); }

edid_pnp() {
    local w c1 c2 c3
    w=$(edid_vid "$1")
    c1=$((((w >> 10) & 31) + 64))
    c2=$((((w >> 5) & 31) + 64))
    c3=$(((w & 31) + 64))
    printf '%s%s%s' "$(chr $c1)" "$(chr $c2)" "$(chr $c3)"
}

# Monitor name (descriptor tag 0xFC) or nothing
edid_name() {
    local h="$1" off
    for off in 54 72 90 108; do
        if [ "${h:$((off * 2)):8}" = "000000fc" ]; then
            printf '%s' "${h:$((off * 2 + 10)):26}" | xxd -r -p | tr -d '\000' | head -n 1 | sed 's/[[:space:]]*$//'
            return 0
        fi
    done
    return 1
}

edid_native() {
    local h="$1" clk hx vy
    clk=$(((16#${h:110:2} << 8) | 16#${h:108:2}))
    if ((clk == 0)); then
        echo "unknown"
        return
    fi
    hx=$((16#${h:112:2} + ((16#${h:116:2} & 240) << 4)))
    vy=$((16#${h:118:2} + ((16#${h:122:2} & 240) << 4)))
    echo "${hx}x${vy}"
}

edid_size() {
    local w h
    w=$(byte "$1" 21)
    h=$(byte "$1" 22)
    if ((w == 0 || h == 0)); then
        echo "not reported"
        return
    fi
    awk -v w="$w" -v h="$h" 'BEGIN { printf "%d x %d cm (about %.1f inch)", w, h, sqrt(w * w + h * h) / 2.54 }'
}

ovr_path() { printf '%s/DisplayVendorID-%x/DisplayProductID-%x' "$OVR_BASE" "$1" "$2"; }

# describe_edid HEX -> aligned details (indented 4 spaces)
describe_edid() {
    local h="$1" vid pid name path oname ext
    vid=$(edid_vid "$h")
    pid=$(edid_pid "$h")
    name=$(edid_name "$h")
    ext=$(byte "$h" 126)
    path=$(ovr_path "$vid" "$pid")

    printf '    %-14s: %s\n' "EDID name" "${name:-<none>}"
    printf '    %-14s: %s\n' "Maker code" "$(edid_pnp "$h")"
    printf '    %-14s: %s%d%s (0x%x)\n' "Vendor ID" "$BLD" "$vid" "$RST" "$vid"
    printf '    %-14s: %s%d%s (0x%x)\n' "Product ID" "$BLD" "$pid" "$RST" "$pid"
    printf '    %-14s: %s\n' "Physical size" "$(edid_size "$h")"
    printf '    %-14s: %s\n' "Native mode" "$(edid_native "$h")"
    printf '    %-14s: %d bytes, %d extension block(s)\n' "EDID size" $((${#h} / 2)) "$ext"
    if checksum_ok "$h"; then
        printf '    %-14s: valid\n' "Checksum"
    else
        printf '    %-14s: %sINVALID%s\n' "Checksum" "$RED" "$RST"
    fi
    if [ -f "$path" ]; then
        oname=$(plutil -extract DisplayProductName raw -o - "$path" 2>/dev/null)
        printf '    %-14s: %s\n' "Override file" "$path"
        printf '    %-14s: %s\n' "Override name" "${oname:-<not set>}"
    else
        printf '    %-14s: none yet (%s)\n' "Override file" "$path"
    fi
}

# ---------------------------------------------------------------------------
# Detecting connected displays
# ---------------------------------------------------------------------------

DET=()

detect_edids() {
    local raw line seen=" "
    DET=()
    # The closing quote after IODisplayEDID skips the IODisplayEDIDOriginal duplicates.
    raw=$(ioreg -lw0 2>/dev/null | sed -n 's/.*"IODisplayEDID" = <\([0-9a-fA-F]*\)>.*/\1/p')
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        line=$(printf '%s' "$line" | tr 'A-F' 'a-f')
        case "$seen" in
        *" $line "*) continue ;;
        esac
        seen="$seen$line "
        DET+=("$line")
    done <<<"$raw"
}

# ---------------------------------------------------------------------------
# Patching the name
# ---------------------------------------------------------------------------

# validate_name NAME -> 0 ok, 1 empty, 2 too long, 3 non-ASCII
validate_name() {
    local n="$1"
    [ -n "$n" ] || return 1
    ((${#n} <= 13)) || return 2
    case "$n" in
    *[!\ -~]*) return 3 ;;
    esac
    return 0
}

# patch_name EDID_HEX NAME -> prints the new EDID hex; returns 1 if there is no free slot
patch_name() {
    local h="$1" name="$2" off="" tag o body n
    n=${#name}
    body=$(printf '%s' "$name" | xxd -p | tr -d '\n')
    ((n < 13)) && body="${body}0a"
    while ((${#body} < 26)); do body="${body}20"; done

    # 1) reuse an existing monitor-name descriptor
    for o in 72 90 108; do
        if [ "${h:$((o * 2)):8}" = "000000fc" ]; then
            off=$o
            break
        fi
    done

    # 2) otherwise take an unused slot: dummy (10), unspecified text (fe), serial string (ff)
    if [ -z "$off" ]; then
        for tag in 10 fe ff; do
            for o in 108 90 72; do
                if [ "${h:$((o * 2)):6}" = "000000" ] && [ "${h:$((o * 2 + 6)):4}" = "${tag}00" ]; then
                    off=$o
                    [ "$tag" = "ff" ] && warn "No free slot, so the serial-number string was replaced by the name."
                    break 2
                fi
            done
        done
    fi

    [ -n "$off" ] || return 1

    h="${h:0:$((off * 2))}000000fc00${body}${h:$((off * 2 + 36))}"
    fix_checksum "$h"
}

# ---------------------------------------------------------------------------
# Patching the override file
# ---------------------------------------------------------------------------

# plist_data_hex FILE KEY -> hex of a <data> value, empty if it cannot be read
plist_data_hex() {
    plutil -extract "$2" xml1 -o - "$1" 2>/dev/null |
        sed -n '/<data>/,/<\/data>/p' | tr -d ' \t\r\n' | sed 's/<[^>]*>//g' |
        (base64 -D 2>/dev/null || base64 -d 2>/dev/null) | xxd -p | tr -d '\n'
}

# rename_embedded FILE NAME NEW_EDID_HEX
# One-Key HiDPI's "with EDID" mode embeds an EDID in the override; keep its name in sync.
rename_embedded() {
    local f="$1" name="$2" fresh="$3" emb newemb old reason=""

    plutil -extract IODisplayEDID xml1 -o - "$f" >/dev/null 2>&1 || return 0

    emb=$(plist_data_hex "$f" IODisplayEDID)
    if [ -z "$emb" ]; then
        reason="the embedded data could not be read"
    elif ! validate_edid "$emb"; then
        reason="$VERR"
    else
        old=$(edid_name "$emb" || true)
        if newemb=$(patch_name "$emb" "$name"); then
            if plutil -replace IODisplayEDID -data "$(hex_to_b64 "$newemb")" "$f"; then
                echo "  Embedded EDID renamed: '${old:-<none>}' -> '$name'"
                return 0
            fi
            reason="writing the new data failed"
        else
            reason="it has no free descriptor slot for a name"
        fi
    fi

    warn "The EDID embedded in the override could not be renamed: $reason."
    if [ -n "$fresh" ] && ask_yn "  Replace the embedded EDID with the new patched EDID instead?" n; then
        if plutil -replace IODisplayEDID -data "$(hex_to_b64 "$fresh")" "$f"; then
            echo "  Embedded EDID replaced with the new patched EDID."
            return 0
        fi
        warn "Could not replace the embedded EDID."
    fi
    echo "  Embedded EDID left unchanged (DisplayProductName is still set)."
}

# patch_override VID PID NAME NEW_EDID_HEX
patch_override() {
    local vid="$1" pid="$2" name="$3" fresh="$4"
    local path dir tmp ts bak

    path=$(ovr_path "$vid" "$pid")
    dir=$(dirname "$path")

    sudo -v || {
        err "sudo is required to write to $OVR_BASE"
        return 1
    }

    tmp=$(mktemp "${TMPDIR:-/tmp}/edidtool.XXXXXX") || return 1

    if [ -f "$path" ]; then
        mkdir -p "$BACKUP_DIR"
        ts=$(date +%Y%m%d-%H%M%S)
        bak="$BACKUP_DIR/$(basename "$dir")_$(basename "$path")_$ts.bak"
        cp "$path" "$bak" 2>/dev/null || sudo cp "$path" "$bak"
        echo "  Backed up the existing override to $bak"
        # tmp is our own file; only the read may need sudo
        # shellcheck disable=SC2024
        cat "$path" >"$tmp" 2>/dev/null || sudo cat "$path" >"$tmp"
    else
        echo "  No override exists for this display yet - creating a minimal one (name only)."
        cat >"$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>DisplayProductName</key>
    <string></string>
    <key>DisplayVendorID</key>
    <integer>$vid</integer>
    <key>DisplayProductID</key>
    <integer>$pid</integer>
</dict>
</plist>
EOF
    fi

    if ! plutil -replace DisplayProductName -string "$name" "$tmp"; then
        err "Could not set DisplayProductName."
        rm -f "$tmp"
        return 1
    fi
    echo "  DisplayProductName set to '$name'"

    rename_embedded "$tmp" "$name" "$fresh"

    if ! plutil -lint "$tmp" >/dev/null; then
        err "The edited override failed validation, nothing was installed."
        rm -f "$tmp"
        return 1
    fi

    sudo mkdir -p "$dir" &&
        sudo cp "$tmp" "$path" &&
        sudo chown root:wheel "$dir" "$path" &&
        sudo chmod 755 "$dir" &&
        sudo chmod 644 "$path" || {
        err "Could not write $path"
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
    return 0
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

ask_yn() {
    local a d="$2" hint
    if [ "$d" = y ]; then hint="Y/n"; else hint="y/N"; fi
    read -r -p "$1 [$hint]: " a
    a=${a:-$d}
    case "$a" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
    esac
}

igpu_path_hint() {
    local p=""
    if command -v gfxutil >/dev/null 2>&1; then
        p=$(gfxutil -f IGPU 2>/dev/null | sed -n 's/.* = //p' | head -n 1)
    fi
    printf '%s' "${p:-PciRoot(0x0)/Pci(0x2,0x0)}"
}

# ---------------------------------------------------------------------------
# Step 1: list displays
# ---------------------------------------------------------------------------

list_displays() {
    local i=0 h
    echo
    echo "$LINE"
    printf '%s%s%s\n' "$BLD" "                       Monitors" "$RST"
    echo "$LINE"
    for h in "${DET[@]}"; do
        i=$((i + 1))
        echo
        printf '%s(%d)%s\n' "$BLD" "$i" "$RST"
        describe_edid "$h"
        printf '    EDID (hex):\n    %s\n' "$h"
    done
    echo
    echo "$LINE"
    echo "Tip: the built-in laptop panel is the one that is about 14 inch with a"
    echo "     1920x1080 native mode."
    echo "$LINE"
}

# ---------------------------------------------------------------------------
# Step 2: choose a display (sets HEX)
# ---------------------------------------------------------------------------

HEX=""

paste_edid() {
    local input
    echo "Paste the EDID hex (or a path to a text file that contains it)."
    read -r -p "EDID: " input
    [ -n "$input" ] || die "Enter error, bye"
    [ -f "$input" ] && input=$(cat "$input")
    HEX=$(clean_hex "$input")
    validate_edid "$HEX" || die "Invalid EDID: $VERR."
    if ((${#HEX} % 256 != 0)); then
        warn "EDID length is not a multiple of 128 bytes - make sure the whole EDID was copied."
    fi
    echo
    echo "This is the EDID you gave me:"
    describe_edid "$HEX"
}

choose_display() {
    local sel
    if [ "${#DET[@]}" -eq 0 ]; then
        warn "No displays were found in ioreg."
        paste_edid
        return
    fi
    read -r -p "Choose the display [1~${#DET[@]}, or p to paste an EDID]: " sel
    case "$sel" in
    p | P)
        paste_edid
        ;;
    *[!0-9]* | "")
        die "Enter error, bye"
        ;;
    *)
        if ((sel < 1 || sel > ${#DET[@]})); then
            die "Enter error, bye"
        fi
        HEX="${DET[$((sel - 1))]}"
        ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 3: rename
# ---------------------------------------------------------------------------

main() {
    local vid pid choice newname newhex rc builtin=n

    if [ "$(uname -s)" != "Darwin" ]; then
        die "This tool is for macOS."
    fi

    echo
    printf '%sDisplay EDID tool%s\n' "$BLD" "$RST"
    echo "$LINE"
    echo "Rename a display on an Intel Hackintosh: patch the monitor name inside its EDID and update the matching display override file in one run. 

Fixes "Unknown Display" in System Settings, Color Profile and Hackintool, and works alongside One-Key HiDPI."
    echo ""
    echo "If you use One-Key HiDPI, run this script after it, not before."
    echo "Re-running One-Key HiDPI overwrites the override and loses the name."

    # ---- 1. list --------------------------------------------------------
    detect_edids
    if [ "${#DET[@]}" -gt 0 ]; then
        list_displays
    fi

    # ---- 2. choose ------------------------------------------------------
    choose_display
    if checksum_ok "$HEX"; then :; else
        warn "The checksum of this EDID is invalid; it will be corrected in the patched copy."
    fi
    vid=$(edid_vid "$HEX")
    pid=$(edid_pid "$HEX")

    echo
    printf 'Your monitor VID:PID: %s%04x:%04x%s\n' "$BLD" "$vid" "$pid" "$RST"
    echo
    echo "(1) Rename a display"
    echo "(2) Quit"
    echo

    read -r -p "Enter your choice [1~2]: " choice
    case "$choice" in
    1) ;;
    2)
        echo "Bye."
        exit 0
        ;;
    *) die "Enter error, bye" ;;
    esac

    # ---- 3. new name ----------------------------------------------------
    read -r -p "Enter the new display name (max 13 characters) [Color LCD]: " newname
    newname=${newname:-Color LCD}
    validate_name "$newname"
    rc=$?
    case $rc in
    1) die "The name cannot be empty." ;;
    2) die "An EDID name holds at most 13 characters; '$newname' has ${#newname}." ;;
    3) die "Use plain ASCII characters only (letters, digits, punctuation, spaces)." ;;
    esac

    if ! newhex=$(patch_name "$HEX" "$newname"); then
        die "No free descriptor slot in this EDID (timings and range limits fill all of them)."
    fi

    # Verify our own output before showing it.
    if [ "$(edid_name "$newhex")" != "$newname" ] || ! checksum_ok "$newhex" || [ "${#newhex}" -ne "${#HEX}" ]; then
        die "Internal check failed on the patched EDID - not using it."
    fi

    echo
    ok "New EDID (name '$newname', checksum valid, $((${#newhex} / 2)) bytes):"
    echo
    echo "$newhex"
    echo

    if ask_yn "Is this the laptop's BUILT-IN screen?" n; then builtin=y; fi

    echo
    echo "Display override for VID:PID $(printf '%04x:%04x' "$vid" "$pid"):"
    if ask_yn "Patch it with the name '$newname' now?" y; then
        if patch_override "$vid" "$pid" "$newname" "$newhex"; then
            echo
            ok "Display override has been patched: $(ovr_path "$vid" "$pid")"
        else
            die "The override was not patched."
        fi
    fi

    echo
    echo "$LINE"
    if [ "$builtin" = y ]; then
        echo "${BLD}Please add the EDID override in your EFI:${RST}"
        echo "  EFI/OC/config.plist -> DeviceProperties -> Add -> $(igpu_path_hint)"
        echo "    Key   : AAPL00,override-no-connect"
        echo "    Type  : Data"
        echo "    Value : the new EDID printed above"
        echo "  Replace any older AAPL00,override-no-connect value instead of adding a second one."
        echo "  Back up your EFI before saving."
    else
        warn "This is an external monitor: do NOT put its EDID in DeviceProperties."
        echo "  The override file alone is enough to rename it."
    fi
    echo "$LINE"
    echo "If the old name still shows after a reboot:"
    echo "  - remove stale profiles in ~/Library/ColorSync/Profiles/Displays/ and"
    echo "    /Library/ColorSync/Profiles/Displays/"
    echo "  - delete /Library/Preferences/com.apple.windowserver*.plist, then reboot again"
    echo "$LINE"
    ok "Done. Please reboot for the changes to take effect."
    exit 0
}

# Run only when executed, not when sourced (lets the helpers be tested).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
