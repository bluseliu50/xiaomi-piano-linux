# Piano touch SPI trial (2026-09-25)

This trial is on descendants of the `milestone-1` tag. The known-good tag and
slot A were not modified. The trial builds from the workspace root with
`./scripts/build-adsp-test-image.sh --jobs "$(nproc)"` and stages its images in
`debian-piano/out/adsp-m1/`.

## Device result

- Confirmed `fastboot getvar current-slot` returned `b` before writing only
  `dtbo_b`; started the matching `boot.img` with `fastboot boot`.
- NCM at `10.42.0.2` came up and the framebuffer remained 3200 x 2136.
  The operator confirmed the screen was still lit after more than two minutes.
- After loading `gpi` and `spi-geni-qcom`, `a88000.spi` bound to `geni_spi` and
  `/sys/bus/spi/devices/spi0.0` appeared with modalias `spi:NVT-ts-spi`.
- `nt36532e_ts` loaded but did not bind. `devices_deferred` reports
  `spi0.0  spi: wait for supplier
  /soc/qcom,mdss_mdp@ae00000/qcom,mdss_dsi_nt37801_wqhd_plus_vid`.
  `/proc/nvt_thp_status` is therefore absent; no touch frames have been read.
- The SCMI protocol `0x10` channel error still appears on the console. It did
  not prevent SPI controller registration; its wider impact is not resolved.

## Binding changes

The stock DT uses `qcom,spi-geni`, clock name `se-clk`, 5-cell GPI DMA, and
1-cell interconnect specifiers. The mainline driver and SM8750 DTS expect
`qcom,geni-spi`, clock name `se`, 3-cell GPI DMA, and 2-cell interconnect
specifiers. The isolated touch overlay maps these properties and enables the
QUP1 wrapper, GPI DMA, and the interconnect providers required by SPI2.
Sources: `linux-piano/arch/arm64/boot/dts/qcom/sm8750.dtsi`,
`linux-piano/drivers/spi/spi-geni-qcom.c`, and the GPI/SPI DT bindings.

The downstream TLMM node at `0xf000000` does not match the mainline TLMM
binding at `0xf100000`. The trial leaves GPIO and touch pin levels untouched
and clears only SPI controller pinctrl references to isolate controller probe.
It does not select a touch firmware image or enable the DRM panel driver.
The next touch step requires a separately reviewed panel/pinctrl plan; the
presence of `spi0.0` alone is not evidence of functional touch input.

The current trial manifest records `boot.img` SHA256
`de649e233b15c98ae014086e5014edb46529adebc713a094cb72cab215028112` and
`dtbo.img` SHA256
`26fe3551ddf82187e11d3c56ad5a936e980ef6889e37f5741d5610b422078a7a`.
The original milestone-1 image pair is retained locally under
`debian-piano/out/test-image/` for slot-B rollback.

## Isolated TLMM trial and follow-up

Commit `0170576` added an independent mainline TLMM node at `0xf100000`,
matching `linux-piano/arch/arm64/boot/dts/qcom/sm8750.dtsi`. The device showed
backlight but no console after that boot attempt. The USB cable was also loose,
so the missing host NCM interface is not conclusive evidence of a kernel crash.
Fastboot later reported `slot-unbootable:b: no`, but `oem lkmsg` returned
`FAILNo such section`; no kernel trace was recoverable. The trial cannot yet
isolate a failure mechanism. The node overlaps the stock `qcom,sun-tlmm`
resource (`0xf000000` + `0x202000`) and was removed in follow-up commit
`0084cb1` to avoid running two TLMM providers over the same hardware.

The follow-up image booted with NCM reachability (3/3 ICMP replies); the
operator confirmed normal console display, and the device remained reachable
after approximately two minutes. `piano-touch-test` again found `a88000.spi`
bound to `geni_spi` and `spi0.0` with modalias `spi:NVT-ts-spi`. Its
`devices_deferred` output names the exact
touch blockers: `spi0.0` waits for the downstream DSI panel node, while
`soc:touch_avdd_vreg` cannot obtain its GPIO. The touch driver also waits for
`panel_on` before checking the chip ID. Forcing probe while the panel and GPIO
providers are unresolved would reach chip I/O with unknown power state; that
is not part of this trial.
