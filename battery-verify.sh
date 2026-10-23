#!/bin/bash
# battery-verify.sh - is a Mac's reported battery health and cycle count real?
#
# Used-laptop sellers can rewrite values inside the battery's gas-gauge chip.
# macOS then faithfully displays the forged numbers: System Settings will report
# "98%" on a pack that actually holds 82%.
#
# Works on ANY Mac with a battery. The core checks need no model data at all, so
# they work on Intel Macs and on models newer than this script. A model table is
# used only to turn the result into an exact percentage.
#
#   bash battery-verify.sh                   normal run
#   bash battery-verify.sh --design-wh 99.6  exact figure for an unlisted model
#   bash battery-verify.sh --raw             also dump every raw register
#
# No admin rights, no installation, no network. Reads only; changes nothing.
# MIT licence.
set -uo pipefail
VERSION="2.0"

# A new pack's measured capacity (Qmax) sits at most about this ratio above its
# design capacity. Used to derive a floor for the genuine design capacity with no
# model data. Raise it to be more conservative (fewer findings, fewer false ones).
QMAX_CEILING=1.07

DESIGN_WH_OVERRIDE=""; SHOW_RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --design-wh) DESIGN_WH_OVERRIDE="${2:-}"; shift 2 ;;
    --raw) SHOW_RAW=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else R=""; G=""; Y=""; B=""; D=""; N=""; fi
hr(){ printf '%s\n' "----------------------------------------------------------------------"; }
head2(){ printf '\n%s%s%s\n' "$B" "$1" "$N"; hr; }
row(){ printf '  %-34s %s\n' "$1" "$2"; }
f(){ awk "BEGIN{printf \"%.$2f\", $1}"; }
gt(){ awk "BEGIN{exit !($1 > $2)}"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PLIST="$TMP/b.plist"
ioreg -arn AppleSmartBattery > "$PLIST" 2>/dev/null
if [ ! -s "$PLIST" ] || ! grep -q AppleSmartBattery "$PLIST" 2>/dev/null; then
  printf '%sNo internal battery found.%s\n' "$R" "$N"
  printf 'This looks like a desktop Mac, or the battery is not detected.\n'; exit 1
fi
g(){ plutil -extract "0.$1" raw -o - "$PLIST" 2>/dev/null; }
num(){ local v; v="$(g "$1")"; case "$v" in ''|*[!0-9-]*) echo "" ;; *) echo "$v" ;; esac; }

MODEL="$(sysctl -n hw.model 2>/dev/null)"
IS_ARM=0; sysctl -n hw.optional.arm64 >/dev/null 2>&1 && IS_ARM=1
PLAT="$(ioreg -rd1 -c IOPlatformExpertDevice -w0 2>/dev/null)"
SERIAL="$(printf '%s' "$PLAT" | tr ',' '\n' | sed -n 's/.*"IOPlatformSerialNumber" = "\([^"]*\)".*/\1/p' | head -1)"
RHEX="$(printf '%s' "$PLAT" | tr ',' '\n' | sed -n 's/.*"region-info" = <\([0-9a-f]*\)>.*/\1/p' | head -1)"
REGION="$(printf '%s' "$RHEX" | xxd -r -p 2>/dev/null | tr -d '\0' | tr -cd '[:print:]')"

DESIGN="$(num DesignCapacity)"; DESIGN_BD="$(num BatteryData.DesignCapacity)"
NCC="$(num NominalChargeCapacity)"; ARMC="$(num AppleRawMaxCapacity)"
CYCLES="$(num CycleCount)"; CCLQ="$(num BatteryData.LifetimeData.CycleCountLastQmax)"
PFS="$(num PermanentFailureStatus)"; BSER="$(g Serial)"; GAUGE="$(g DeviceName)"
PCT="$(num CurrentCapacity)"; DCC="$(num DesignCycleCount9C)"

QMAX=""; for i in 0 1 2 3; do
  q="$(num BatteryData.Qmax.$i)"; [ -n "$q" ] && { [ -z "$QMAX" ] && QMAX="$q" || { gt "$q" "$QMAX" && QMAX="$q"; }; }
done
CELLS=0; for i in 0 1 2 3 4 5; do [ -n "$(num BatteryData.CellVoltage.$i)" ] && CELLS=$((CELLS+1)); done
[ "$CELLS" -eq 0 ] && CELLS=3
VNOM_CELL=3.819

SP="$(system_profiler SPPowerDataType 2>/dev/null)"
SHOWN_MAX="$(printf '%s' "$SP" | sed -n 's/.*Maximum Capacity: *\([0-9]*\)%.*/\1/p' | head -1)"
SHOWN_CYC="$(printf '%s' "$SP" | sed -n 's/.*Cycle Count: *\([0-9]*\).*/\1/p' | head -1)"
SHOWN_COND="$(printf '%s' "$SP" | sed -n 's/.*Condition: *\(.*\)/\1/p' | head -1 | tr -d '\r')"
# ---------- Apple's published watt-hour ratings ----------
# VERIFIED  = checked against Apple's own specification page; the URL is on the line.
# COMMUNITY = widely reported but not confirmed against a primary source; the script
#             labels it as unverified when it uses it.
#
# Apple rounds the headline figure on its spec pages ("70-watt-hour lithium-polymer
# battery", "100-watt-hour") and gives the true rating in a footnote: "Actual rating of
# 69.6 watt-hours (14-inch model) or 99.6 watt-hours (16-inch model)." The footnote
# figure is what is recorded here. Where the headline already carries a decimal - 72.4,
# 66.5, 58.2, 53.8, 52.6, 49.9 - that headline IS the actual rating and no footnote
# refines it. Taking the headline 70 or 100 instead would put the reference 0.4% to 0.6%
# off and weaken the comparison.
#
# Only the watt-hour rating is needed; the script converts to mAh itself and reads the
# cell count from the pack. Apple's packs are nominally 11.39 V to 11.58 V, so a single
# 3.819 V/cell constant lands within 0.8% of every pack's own mAh label - well inside the
# 3% tolerance the design-capacity check uses.
design_wh_for_model() {
  case "$1" in
    # ---- M1  (2020-2021) ----
    MacBookAir10,1)                 echo "49.9 VERIFIED" ;;  # Air 13-inch M1           https://support.apple.com/en-us/111883
    MacBookPro17,1)                 echo "58.2 VERIFIED" ;;  # Pro 13-inch M1           https://support.apple.com/en-us/111893
    MacBookPro18,3|MacBookPro18,4)  echo "69.6 VERIFIED" ;;  # Pro 14-inch M1 Pro/Max   https://support.apple.com/en-us/111902
    MacBookPro18,1|MacBookPro18,2)  echo "99.6 VERIFIED" ;;  # Pro 16-inch M1 Pro/Max   https://support.apple.com/en-us/111901
    # ---- M2  (2022-2023) ----
    Mac14,2)                        echo "52.6 VERIFIED" ;;  # Air 13-inch M2           https://support.apple.com/en-us/111867
    Mac14,15)                       echo "66.5 VERIFIED" ;;  # Air 15-inch M2           https://support.apple.com/en-us/111346
    Mac14,7)                        echo "58.2 VERIFIED" ;;  # Pro 13-inch M2           https://support.apple.com/en-us/111869
    Mac14,5|Mac14,9)                echo "69.6 VERIFIED" ;;  # Pro 14-inch M2 Pro/Max   https://support.apple.com/en-us/111340
    Mac14,6|Mac14,10)               echo "99.6 VERIFIED" ;;  # Pro 16-inch M2 Pro/Max   https://support.apple.com/en-us/111838
    # ---- M3  (2023-2024) ----
    Mac15,12)                       echo "52.6 VERIFIED" ;;  # Air 13-inch M3           https://support.apple.com/en-us/118551
    Mac15,13)                       echo "66.5 VERIFIED" ;;  # Air 15-inch M3           https://support.apple.com/en-us/118552
    Mac15,3)                        echo "69.6 VERIFIED" ;;  # Pro 14-inch M3           https://support.apple.com/en-us/117735
    Mac15,6|Mac15,8|Mac15,10)       echo "72.4 VERIFIED" ;;  # Pro 14-inch M3 Pro/Max   https://support.apple.com/en-us/117736
    Mac15,7|Mac15,9|Mac15,11)       echo "99.6 VERIFIED" ;;  # Pro 16-inch M3 Pro/Max   https://support.apple.com/en-us/117737
    # ---- M4  (2024-2025) ----
    Mac16,12)                       echo "53.8 VERIFIED" ;;  # Air 13-inch M4           https://support.apple.com/en-us/122209
    Mac16,13)                       echo "66.5 VERIFIED" ;;  # Air 15-inch M4           https://support.apple.com/en-us/122210
    Mac16,1)                        echo "72.4 VERIFIED" ;;  # Pro 14-inch M4           https://support.apple.com/en-us/121552
    Mac16,6|Mac16,8)                echo "72.4 VERIFIED" ;;  # Pro 14-inch M4 Pro/Max   https://support.apple.com/en-us/121553
    Mac16,5|Mac16,7)                echo "99.6 VERIFIED" ;;  # Pro 16-inch M4 Pro/Max   https://support.apple.com/en-us/121554
    # ---- M5  (2025-2026) ----
    Mac17,3)                        echo "53.8 VERIFIED" ;;  # Air 13-inch M5           https://support.apple.com/en-us/126320
    Mac17,4)                        echo "66.5 VERIFIED" ;;  # Air 15-inch M5           https://support.apple.com/en-us/126321
    Mac17,2)                        echo "72.4 VERIFIED" ;;  # Pro 14-inch M5           https://support.apple.com/en-us/125405
    Mac17,7|Mac17,9)                echo "72.4 VERIFIED" ;;  # Pro 14-inch M5 Pro/Max   https://support.apple.com/en-us/126318
    Mac17,6|Mac17,8)                echo "99.6 VERIFIED" ;;  # Pro 16-inch M5 Pro/Max   https://support.apple.com/en-us/126319
    *)                              echo "" ;;
  esac
}

PLAUSIBLE_WH="49.9 52.6 53.8 58.2 66.5 69.6 72.4 99.6 100"

WH_GAUGE=""; [ -n "$DESIGN" ] && WH_GAUGE="$(f "$DESIGN * $CELLS * $VNOM_CELL / 1000" 1)"
SRC="none"; DESIGN_WH=""; DESIGN_REF=""
if [ -n "$DESIGN_WH_OVERRIDE" ]; then DESIGN_WH="$DESIGN_WH_OVERRIDE"; SRC="override"
else E="$(design_wh_for_model "$MODEL")"; [ -n "$E" ] && { DESIGN_WH="${E%% *}"; SRC="${E##* }"; }; fi
[ -n "$DESIGN_WH" ] && DESIGN_REF="$(f "$DESIGN_WH * 1000 / ($CELLS * $VNOM_CELL)" 0)"

# ---- the model-free floor: a pack's design capacity cannot sit below Qmax/ceiling
FLOOR=""; [ -n "$QMAX" ] && FLOOR="$(f "$QMAX / $QMAX_CEILING" 0)"
CAP_BOUND=""; [ -n "$FLOOR" ] && [ -n "$NCC" ] && CAP_BOUND="$(f "$NCC * 100 / $FLOOR" 1)"

printf '%s======================================================================%s\n' "$B" "$N"
printf '%s  Mac battery verifier v%s%s\n' "$B" "$VERSION" "$N"
printf '%s======================================================================%s\n' "$B" "$N"

head2 "MACHINE"
row "Model identifier" "$MODEL$([ "$IS_ARM" -eq 1 ] && echo '  (Apple silicon)' || echo '  (Intel)')"
row "Serial" "${SERIAL:-unknown}"; [ -n "$REGION" ] && row "Region code" "$REGION"
row "Battery serial" "${BSER:-unknown}"; row "Gas gauge" "${GAUGE:-unknown}"
row "Pack" "${CELLS} cells in series"

head2 "WHAT THE SYSTEM SHOWS YOU   (System Settings > Battery)"
row "Cycle count" "${SHOWN_CYC:-$CYCLES}"
row "Maximum capacity" "${SHOWN_MAX:-?}%"
row "Condition" "${SHOWN_COND:-?}"
row "Total runtime on battery" "${D}not shown - macOS has no such figure${N}"

head2 "PART 1 - ANALYSIS THAT NEEDS NO MODEL DATA"
printf '  %sThis section works on any Mac, including Intel models and models newer\n' "$D"
printf '  than this script. Nothing here is looked up.%s\n\n' "$N"
row "Design capacity, as reported" "${DESIGN:-?} mAh${DESIGN_BD:+  (and $DESIGN_BD in BatteryData)}"
row "Measured cell capacity (Qmax)" "${QMAX:-?} mAh"
if [ -n "$FLOOR" ]; then
  row "=> genuine design must be >=" "$FLOOR mAh   ${D}(Qmax / $QMAX_CEILING)${N}"
  if gt "$FLOOR" "$DESIGN"; then
    printf '  %s=> the reported design capacity is BELOW that floor: UNDERSTATED%s\n' "$R$B" "$N"
  else
    printf '  %s=> the reported design capacity is consistent with the cells%s\n' "$G" "$N"
  fi
  echo
  [ -n "$CAP_BOUND" ] && row "Upper bound on true health" "${B}${CAP_BOUND}%${N}   ${D}(cannot be higher than this)${N}"
  if [ -n "$CAP_BOUND" ] && [ -n "$SHOWN_MAX" ] && gt "$SHOWN_MAX" "$CAP_BOUND"; then
    printf '  %s=> the %s%% on screen EXCEEDS that bound, so it cannot be true%s\n' "$R$B" "$SHOWN_MAX" "$N"
  fi
fi
if [ -n "$CCLQ" ] && [ -n "$CYCLES" ]; then
  echo; row "Cycle count, as reported" "$CYCLES"
  row "Cycles at last capacity relearn" "$CCLQ"
  if [ "$CCLQ" -gt "$CYCLES" ] 2>/dev/null; then
    printf '  %s=> a relearn was logged at cycle %s, so the counter was rolled back.\n' "$R$B" "$CCLQ"
    printf '     True cycles are AT LEAST %s, not %s.%s\n' "$CCLQ" "$CYCLES" "$N"
  else
    printf '  %s=> consistent; no sign the counter was reset%s\n' "$G" "$N"
  fi
fi

head2 "PART 2 - EXACT FIGURE"
if [ -n "$DESIGN_REF" ]; then
  case "$SRC" in
    VERIFIED)  row "Apple's rating for this model" "$DESIGN_WH Wh = $DESIGN_REF mAh  ${G}[verified]${N}" ;;
    COMMUNITY) row "Apple's rating for this model" "$DESIGN_WH Wh = $DESIGN_REF mAh  ${Y}[unconfirmed]${N}" ;;
    override)  row "Rating you supplied" "$DESIGN_WH Wh = $DESIGN_REF mAh" ;;
  esac
  row "Full charge capacity now" "${ARMC:-?} mAh"
  A="$(f "$NCC * 100 / $DESIGN_REF" 1)"; Bv="$(f "$ARMC * 100 / $DESIGN_REF" 1)"
  if gt "$A" "$Bv"; then H_LO="$Bv"; H_HI="$A"; else H_LO="$A"; H_HI="$Bv"; fi
  printf '  %-34s %s%s%% - %s%%%s\n' "REAL HEALTH" "$B$G" "$H_LO" "$H_HI" "$N"
  [ -n "$SHOWN_MAX" ] && printf '  %-34s %s\n' "" "${D}system claims ${SHOWN_MAX}%${N}"
else
  printf '  %sNo Apple rating on file for %s, so an exact percentage is not\n' "$Y" "$MODEL"
  printf '  available. Part 1 above still stands on its own.%s\n\n' "$N"
  printf '  To get the exact figure: open Apple'"'"'s tech-spec page for this model, read\n'
  printf '  the battery watt-hour rating (use the FOOTNOTE value, not the rounded\n'
  printf '  headline), then re-run:\n'
  printf '    %sbash %s --design-wh <value>%s\n' "$B" "$(basename "$0")" "$N"
fi

FAIL=0; RUN=0; SKIP=0
ok(){ RUN=$((RUN+1)); printf '  %s[PASS]%s %s\n' "$G" "$N" "$1"; }
bad(){ RUN=$((RUN+1)); FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$R" "$N" "$1"; printf '         %s%s%s\n' "$D" "$2" "$N"; }
warn(){ RUN=$((RUN+1)); printf '  %s[WARN]%s %s\n' "$Y" "$N" "$1"; printf '         %s%s%s\n' "$D" "$2" "$N"; }
skip(){ SKIP=$((SKIP+1)); printf '  %s[ -- ]%s %s\n' "$D" "$N" "$1"; printf '         %s%s%s\n' "$D" "$2" "$N"; }

head2 "CHECKS"
if [ -n "$FLOOR" ] && [ -n "$DESIGN" ]; then
  if gt "$FLOOR" "$DESIGN"; then
    bad "Design capacity consistent with the cells  [no model data needed]" \
        "cells measure $QMAX mAh, so design cannot be below $FLOOR mAh, yet it reports $DESIGN mAh"
  else ok "Design capacity consistent with the cells  [no model data needed]"; fi
else skip "Design capacity consistent with the cells" "Qmax not exposed on this Mac"; fi

if [ -n "$CCLQ" ] && [ -n "$CYCLES" ]; then
  if [ "$CCLQ" -gt "$CYCLES" ] 2>/dev/null; then
    bad "Cycle counter agrees with the lifetime log  [no model data needed]" \
        "counter reads $CYCLES but a relearn was logged at cycle $CCLQ; the counter only ever increases"
  else ok "Cycle counter agrees with the lifetime log  [no model data needed]"; fi
else skip "Cycle counter agrees with the lifetime log" "lifetime log not exposed on this Mac"; fi

if [ -n "$CAP_BOUND" ] && [ -n "$SHOWN_MAX" ]; then
  if gt "$SHOWN_MAX" "$CAP_BOUND"; then
    bad "Displayed health within the physical bound  [no model data needed]" \
        "screen says ${SHOWN_MAX}% but the cells cap it at ${CAP_BOUND}%"
  else ok "Displayed health within the physical bound  [no model data needed]"; fi
else skip "Displayed health within the physical bound" "needs Qmax and the displayed figure"; fi

if [ -n "$DESIGN_REF" ] && [ -n "$DESIGN" ]; then
  DIFF="$(f "($DESIGN_REF - $DESIGN) * 100 / $DESIGN_REF" 1)"
  if gt "$DIFF" 3; then
    bad "Design capacity matches Apple's published rating" \
        "reports $DESIGN mAh, Apple publishes $DESIGN_REF mAh - $(f "$DIFF" 1)% low"
  elif gt "-3" "$DIFF"; then
    warn "Design capacity matches Apple's published rating" "reports MORE than Apple's rating ($(f "$DIFF" 1)%)"
  else ok "Design capacity matches Apple's published rating"; fi
else skip "Design capacity matches Apple's published rating" "no rating for $MODEL - use --design-wh"; fi

if [ "$IS_ARM" -eq 1 ] && [ -n "$WH_GAUGE" ]; then
  BEST=""; BESTD=""
  for w in $PLAUSIBLE_WH; do
    dd="$(awk "BEGIN{d=($WH_GAUGE-$w); if(d<0)d=-d; printf \"%.3f\", d*100/$w}")"
    if [ -z "$BESTD" ] || gt "$BESTD" "$dd"; then BESTD="$dd"; BEST="$w"; fi
  done
  if gt "$BESTD" 3; then
    bad "Implied rating matches a real Apple battery" \
        "design capacity works out to ${WH_GAUGE} Wh; Apple ships no such pack, nearest is ${BEST} Wh ($(f "$BESTD" 1)% away)"
  else ok "Implied rating matches a real Apple battery  (${WH_GAUGE} Wh ~ ${BEST} Wh)"; fi
else
  skip "Implied rating matches a real Apple battery" "Intel Mac - the rating list here covers Apple silicon only"
fi

[ -n "$PFS" ] && { [ "$PFS" -eq 0 ] 2>/dev/null && ok "No permanent battery fault flagged" || bad "No permanent battery fault flagged" "PermanentFailureStatus = $PFS"; }
if csrutil status 2>/dev/null | grep -q enabled; then
  if codesign -v /usr/sbin/ioreg /usr/sbin/system_profiler >/dev/null 2>&1; then ok "System integrity intact, tools genuine"
  else warn "System integrity intact, tools genuine" "could not verify the reporting tools' signatures"; fi
else warn "System integrity intact, tools genuine" "SIP is DISABLED - readings on this Mac could be faked in software"; fi

head2 "RUNTIME  -  read this"
printf '  %sNo Mac records how long it has run on battery. There is no such counter\n' "$D"
printf '  in the hardware or the OS. Anything showing you one is guessing.%s\n' "$N"
REAL_CYC="$CYCLES"; NOTE="as reported"
if [ -n "$CCLQ" ] && [ -n "$CYCLES" ] && [ "$CCLQ" -gt "$CYCLES" ] 2>/dev/null; then REAL_CYC="$CCLQ"; NOTE="using the >= $CCLQ floor, not the reported $CYCLES"; fi
if [ -n "$REAL_CYC" ] && [ -n "$DESIGN_WH" ]; then
  EH="$(f "$REAL_CYC * $DESIGN_WH" 0)"; echo
  row "Energy drawn over its life" "~${EH} Wh  (${REAL_CYC} cycles x ${DESIGN_WH} Wh)"
  row "  at a light 10 W load" "~$(f "$EH / 10" 0) h on battery"
  row "  at a heavy 30 W load" "~$(f "$EH / 30" 0) h on battery"
  printf '  %sArithmetic from the cycle count (%s). Order of magnitude only.%s\n' "$D" "$NOTE" "$N"
fi
[ -n "$DCC" ] && { echo; row "Design cycle rating" "$DCC cycles  ${D}(service threshold is 80% health)${N}"; }

head2 "VERDICT"
if [ "$FAIL" -gt 0 ]; then
  printf '  %s%s of %s checks FAILED.%s\n\n' "$R$B" "$FAIL" "$RUN" "$N"
  printf '  This battery reports figures that contradict its own hardware.\n'
  printf '  Treat the health percentage and cycle count on screen as unreliable.\n'
  [ -n "${H_LO:-}" ] && printf '  Real health: %s%s%% - %s%%%s, not %s%%.\n' "$B" "$H_LO" "$H_HI" "$N" "${SHOWN_MAX:-?}"
  [ -z "${H_LO:-}" ] && [ -n "$CAP_BOUND" ] && printf '  Real health is at most %s%s%%%s, not %s%%.\n' "$B" "$CAP_BOUND" "$N" "${SHOWN_MAX:-?}"
  [ -n "$CCLQ" ] && [ "$CCLQ" -gt "${CYCLES:-0}" ] 2>/dev/null && printf '  Real cycles: at least %s%s%s, not %s.\n' "$B" "$CCLQ" "$N" "$CYCLES"
elif [ "$SKIP" -gt 0 ]; then
  printf '  %sNo contradictions found in %s checks (%s skipped).%s\n\n' "$G$B" "$RUN" "$SKIP" "$N"
  printf '  Nothing suspicious. The skipped checks leave gaps - supply this model'"'"'s\n'
  printf '  watt-hour rating with --design-wh to close them.\n'
else
  printf '  %sAll %s checks passed.%s\n\n' "$G$B" "$RUN" "$N"
  printf '  Reported health and cycle count are consistent with the hardware.\n'
fi

printf '\n%sone-line summary (paste this back):\n' "$D"
printf '%s | %s | shown %s%%/%sc | real %s%%/>=%sc | %s/%s failed | v%s\n' \
  "$MODEL" "${SERIAL:-?}" "${SHOWN_MAX:-?}" "${SHOWN_CYC:-?}" \
  "${H_LO:-<=$CAP_BOUND}${H_HI:+-$H_HI}" "${CCLQ:-${CYCLES:-?}}" "$FAIL" "$RUN" "$VERSION"
printf '%s' "$N"
[ "$SHOW_RAW" -eq 1 ] && { head2 "RAW REGISTERS"; plutil -p "$PLIST" 2>/dev/null | sed 's/^/  /'; }
echo
exit 0
