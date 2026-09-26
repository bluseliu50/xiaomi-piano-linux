# WLAN/BT bring-up (peach combo, WCN7850 family) — 2026-09-26 round

Branches: linux-piano `piano/wlanbt` (2 commits on milestone-touch),
debian-piano `bp/wlanbt`, umbrella `build/wlanbt`.  The milestone-touch
overlay is included verbatim; everything new lives in
`debian-piano/boot/dtbo-piano-wlanbt.dts` and the background ladder in
`debian-piano/initramfs/init`.

## What this round adds

Target: the two remaining self-contained peripherals — WLAN (ath12k over
pcie0) and Bluetooth (hci_qca over uart14).  Both halves of the combo chip
are powered through one `qcom,wcn7850-pmu` power sequencer.

### Kernel (linux-piano)

- `pci-pwrctrl-pwrseq` now also matches `pci17cb,110e` (the peach compute
  SKU; ath12k already accepts the ID from commit d9256fa86).
- `CONFIG_PCI_PWRCTRL_PWRSEQ=m`; `PCIE_QCOM` stays built-in (it is a *bool*
  in this kernel — `=m` silently drops the symbol).  This is safe: the
  pcie-qcom host probe defers on the `wifi@0` pwrctrl device until
  `pci-pwrctrl-pwrseq` binds, so boot stays passive.

### DTBO (fragments 229-235 on top of milestone-touch)

- **229** mainline `rpmh-regulators` blocks as direct children of
  `apps_rsc` for exactly the PMU input rails: S1D/S4D (d), S5F/L1F/L2F/L3F
  (f), S3G/L3G (g), S7I (i).  Windows mirror the stock
  `qcom,init-voltage` values; nothing is always-on — rails switch only
  when the pwrseq powers the combo.
- **230** `vph_pwr` fixed regulator + the `wcn7850-pmu` unit
  (WLAN_EN = tlmm16, BT_EN = pm8550ve_f gpio3, RF_CLK1 via rpmhcc).
- **231** pin states on the mainline TLMM node from touch-v2: wlan_en,
  uart14 (TX26/RX27/CTS24/RTS25 — stock `qupv3_se14_*` mapping), and the
  upstream pcie0 default state (perst102/clkreq103/wake104).
- **232** uart14 → `qcom,geni-uart` with the `qcom,wcn7850-bt` serdev
  child.  Vendor pinctrl-1/2/3 neutered; mainline SE clock + 2-path
  interconnects.
- **233** pcie0 → mainline binding: reg/interrupts/clocks/resets from
  upstream sm8750.dtsi, msi0..msi7 split-MSI (no ITS in the stock tree —
  the stock msi-map/iommu-map are neutered empty; stock `ranges` and
  `dma-coherent` kept).
- **234** `qcom,sm8750-qmp-gen3x2-pcie-phy` at 0x1c06000 (upstream copy,
  1-cell reg, supplies from the new regulators).
- **235** port child: `reset-gpios`/`wake-gpios` + the `pci17cb,110e`
  `wifi@0` pwrctrl child with the PMU LDO supplies.

### initramfs

- `piano-qup-smmu` at boot now also matches QUP2 (0x436/0x423 — uart14
  runs GENI SE DMA mode) and PCIe0 (0x1400/0x1401 — the stock
  `qcom,smmu-sid-base`).
- Background ladder (after telnetd, one module per step, kmsg marker
  before each, `/run/wlanbt-stages.log`):
  TLMM → pwrseq-qcom-wcn → hci_uart (BT power + firmware) →
  pci-pwrctrl-pwrseq (WLAN power) → phy-qcom-qmp-pcie → pcie (deferred
  built-in probe completes) → ath12k → report.

## Expected observations (per stage)

- Stage 2: `hci0` appears with a BD address once `qca/hmtbtfw20.tlv` +
  `hmtnv20*` download over uart14 succeeds.
- Stage 3-4: PCI function `17cb:110e` appears under `/sys/bus/pci`.
- Stage 5: `phy0` under `/sys/class/ieee80211` after
  `ath12k/WCN7850/hw2.0/{amss,m3,board-2,bdwlan}.bin`.

## Known risks / open questions

- The first RPMh *commands* ever issued on this device are the regulator
  enables in the pwrseq power-on (rpmh-rsc/rpmhcc were bound but no
  consumer has voted yet).  A refusal surfaces as a clean pwrseq error.
- `pm8550ve_f_gpios` must be bound by `pinctrl-spmi-gpio` (built-in) for
  BT_EN; the stock node carries the matching compatible.  If it is not
  bound, pwrseq probe fails with a clear message.
- ath12k on the peach SKU is an experiment routed through the WCN7850
  probe path; if CE configs differ, probe fails cleanly in dmesg.

## Device recipe (unchanged flow)

```
fastboot getvar current-slot        # must be b
fastboot flash dtbo_b debian-piano/out/test-image/dtbo.img
fastboot boot debian-piano/out/test-image/boot.img
# host: nmcli connection up piano-ncm; telnet 10.42.0.2 23
piano-tests                         # menu 5/6, or wait for the ladder
cat /run/wlanbt-stages.log          # stage-by-stage evidence
```

Rollback: re-flash the milestone-touch dtbo_b (`git checkout milestone-touch
-- boot/` or rebuild) and RAM-boot the milestone boot.img; slot A stays
untouched throughout.

## Results

*(filled after the device round)*
