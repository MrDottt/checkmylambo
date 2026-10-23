# battery-verify

Check whether a Mac's reported battery health and cycle count are **real**.

Used-laptop sellers can rewrite values inside the battery's gas-gauge chip. macOS then
faithfully displays the forged numbers — System Settings will happily tell you "98%" on a
battery that is actually at 82%. This script compares what the system shows against what
the hardware's own internal cross-checks imply, and tells you when they disagree.

Runs in **under half a second**. No installation, no admin password, no network, no
Homebrew, no Python. Reads only — it changes nothing.

---

## Use it

Paste this into Terminal on any Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/MrDottt/checkmylambo/refs/heads/main/battery-verify.sh | bash
```

That is the whole thing. It takes about half a second, needs no admin password, installs
nothing, and changes nothing on the machine — it only reads.

To pass an option through the pipe, put it after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/MrDottt/checkmylambo/refs/heads/main/battery-verify.sh | bash -s -- --design-wh 99.6
```

Options: `--design-wh <value>` supplies Apple's watt-hour rating for a model that isn't in
the table, `--raw` also dumps every battery register, `--help` prints usage.

### Prefer to read it first?

The command above runs code straight from the internet without showing it to you. That is
normal for install one-liners, but if you would rather look before running — sensible when
you are about to run something on someone else's laptop — download it, read it, then run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/MrDottt/checkmylambo/refs/heads/main/battery-verify.sh
less battery-verify.sh
chmod +x battery-verify.sh
./battery-verify.sh
```

`chmod +x` sets the execute bit so you can run it as `./battery-verify.sh`. You only need it
once per download, and only for this path — the one-liner above pipes the script into `bash`,
which never needs the execute bit.

If you would rather skip `chmod`, this works on a freshly downloaded file as-is:

```bash
bash battery-verify.sh
```

Same result from all three.

### Keeping it for repeat use

Testing a stack of laptops from a USB stick or a shared folder? Download it once, make it
executable, and run it per machine:

```bash
chmod +x battery-verify.sh          # once
./battery-verify.sh                 # on each Mac
./battery-verify.sh --design-wh 69.6   # if the model is not in the table
```

The execute bit survives copying to another Mac over AirDrop or a network share, but **not**
a round trip through a FAT/exFAT USB stick or a zip file — if `./battery-verify.sh` returns
`Permission denied`, just run `chmod +x battery-verify.sh` again.

## What a tampered battery looks like

```
WHAT THE SYSTEM SHOWS YOU   (System Settings > Battery)
  Cycle count                        99
  Maximum capacity                   98%
  Condition                          Normal

WHAT THE HARDWARE ACTUALLY SAYS
  Design capacity, per the battery   7610 mAh   = 87.2 Wh
  Design capacity, per Apple         8693 mAh   = 99.6 Wh  [verified]
  Full charge capacity now           7176 mAh
  Learned cell capacity (Qmax)       8318 mAh

  REAL HEALTH                        82.5% - 85.4%
                                     system claims 98%
  REAL CYCLE COUNT                   >= 241
                                     system claims 99

CONSISTENCY CHECKS
  [FAIL] Design capacity matches Apple's published rating
  [FAIL] Cycle counter agrees with the battery's lifetime log
  [FAIL] Learned capacity fits within design capacity
  [FAIL] Implied rating matches a real Apple battery
  [PASS] No permanent battery fault flagged
  [PASS] System integrity intact, tools genuine

VERDICT
  4 of 6 checks FAILED.
  Best estimate of real health: 82.5% - 85.4%, not 98%.
```

A clean machine prints `All 6 checks passed.`

---

## How it works

macOS calculates battery health as **full-charge capacity ÷ design capacity**, and *both*
numbers come from inside the battery itself. Understate the design capacity and the
percentage goes up, with no other visible change. That one edit is the usual trick, and it
survives erasing the Mac, reinstalling macOS, and even a DFU restore — because it lives in
the battery, not on the disk.

The script reports in two parts.

### Part 1 — needs no model data

Works on **any** Mac with a battery: Intel, Apple silicon, and models released after this
script was written. Nothing is looked up.

It rests on one physical fact: **a pack's design capacity cannot sit below the capacity its
own cells measure.** The gauge continuously measures the cells and stores the result as
`Qmax`. A brand-new pack reads at most about 107% of design, and the figure only falls with
age. So:

```
genuine design capacity  >=  Qmax / 1.07
```

If the reported design capacity is below that floor, it has been understated — and the same
floor caps how high the health percentage can possibly be. On a tampered pack the figure on
screen exceeds its own physical ceiling, which is provable without knowing the model.

The cycle check is likewise self-contained. The battery separately records the cycle count at
its last capacity relearn. The counter only ever increases, so that record can never exceed
the current count. When it does, the visible counter was rolled back, and the true count is
at least the recorded value.

### Part 2 — the exact percentage

Turning Part 1 into a precise number needs Apple's published watt-hour rating, which **macOS
does not store anywhere** — verified: no system plist, no device-tree entry. So the script
carries a table, and falls back to `--design-wh` for anything not in it.

| Check | Catches | Needs the table? |
|---|---|---|
| Design capacity vs the cells' own measurement | design constant lowered | **no** |
| Cycle counter vs lifetime relearn log | cycle counter reset | **no** |
| Displayed health vs its physical ceiling | health inflated | **no** |
| Implied rating vs real Apple ratings | design value Apple never shipped | no (Apple silicon only) |
| Design capacity vs Apple's published rating | design constant lowered, exactly | yes |
| Permanent failure flag | a genuinely failing pack | no |
| SIP + binary signatures | macOS itself tampered with | no |

**Three of the four tamper checks need no reference data**, so a model the script has never
heard of still gets caught. On an unlisted model you lose only the exact figure: you still
get "health is at most X%" and "cycles are at least Y".

## What this script will not tell you

Being straight about this, because other tools are not:

- **Total time run on battery.** No Mac records it. There is no such counter in the hardware
  or the OS. The script prints an order-of-magnitude estimate derived from the cycle count
  and labels it as arithmetic, not measurement. Anything that shows you a confident
  battery-runtime figure is guessing.
- **The exact cycle count**, when a rollback is detected. The lifetime record gives a
  *floor* — "at least 241" — not the true total.
- **Whether the battery is genuine or counterfeit.** The fields that would identify a pack
  (serial, manufacturer, chemistry ID) are stored in the same chip whose other contents are
  in doubt, so they cannot authenticate anything.
- **Who did it, or when.** The script reports the state of the hardware. It cannot establish
  chain of custody, and an honest reseller may have bought the machine this way.
- **A precise health figure.** The capacity estimators drift by well under a percent as the
  battery charges and discharges, so the script reports a range. That drift is far smaller
  than the gap a tampered design constant creates.

If System Integrity Protection is **disabled**, the script warns you: on such a machine the
readings themselves could be faked in software, and nothing it reports can be trusted.

---

## Optional: SSD power-on hours

If `smartctl` is on `PATH`, the script also reports the SSD's power-on hours — total
*system-on* time, not battery time. Build it without admin rights or Homebrew:

```bash
mkdir -p ~/smartmontools && cd ~/smartmontools
curl -fsSLO https://downloads.sourceforge.net/project/smartmontools/smartmontools/7.5/smartmontools-7.5.tar.gz
tar xzf smartmontools-7.5.tar.gz && cd smartmontools-7.5
./configure --prefix="$PWD/../prefix" && make -j"$(sysctl -n hw.ncpu)" && make install
export PATH="$HOME/smartmontools/prefix/sbin:$PATH"
```

Needs only the Xcode command line tools. Treat the number with care: Apple's NVMe
implementation is partial on some Macs (`Controller Busy Time` reads 0, the error log is
unreadable), and the field has not been observed to increment on all machines.

---

## Reference table

Only Part 2 uses it. `sysctl -n hw.model` prints your identifier.

Every Apple silicon MacBook — M1 through M5, Air and Pro, every size — is listed, each
checked against Apple's own specification page, with the URL in the comment on the line.
**Intel Macs are not listed**; use `--design-wh` for those. Part 1 works regardless.

Adding a model is one line:

```bash
MacBookPro16,1)  echo "100 VERIFIED" ;;  # Intel 16-inch 2019  <Apple spec page URL>
```

Read the **footnote** rating on Apple's page, not the rounded headline — the 16-inch page
says "100-watt-hour" while its footnote gives the real 99.6 Wh. Getting this wrong matters:
within a generation the 14-inch and 16-inch differ by one digit of the identifier, and the
two sizes did not change together. The 14-inch was 69.6 Wh from M1 Pro through the base M3,
then 72.4 Wh for M3 Pro/Max onward, while every 16-inch from M1 Pro to M5 Max has been
99.6 Wh. Using the widely-repeated 72.4 Wh for a 14-inch M2 Pro overstates the reference by
4% — past the 3% tolerance, so it would accuse an honest battery.

`PLAUSIBLE_WH`, just below the table, is the flat set of ratings Apple actually ships, used
by the "implied rating" check. A genuinely new rating must be added in both places.

Pull requests welcome — new identifiers, and corrections with a link to Apple's page.

## Caveats

- Part 1 works on Intel and Apple silicon alike. On Intel the "implied rating" check is
  skipped (its list covers Apple silicon ratings) and no model is in the table, so pass
  `--design-wh` for an exact figure.
- The Part 1 floor assumes the gauge's `Qmax` is honest. It is a continuously re-measured
  value rather than a stored constant, which makes it a poor forgery target — but if a
  tool rewrote it too, these checks would weaken. The cycle-log check is independent of it.
- Requires macOS 11 or later. Uses only `ioreg`, `plutil`, `system_profiler`, `sysctl`,
  `csrutil`, `codesign` and `awk` — all present on a stock system.
- A `[FAIL]` is evidence of an inconsistency, not proof of fraud. Read what it says.

## Licence

MIT.
