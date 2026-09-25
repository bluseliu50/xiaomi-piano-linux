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
`34f5c4e411972cfaeee67a92c5eb847771ed7e3cdb432e544b364fb2f2217b11` and
`dtbo.img` SHA256
`26fe3551ddf82187e11d3c56ad5a936e980ef6889e37f5741d5610b422078a7a`.
The original milestone-1 image pair is retained locally under
`debian-piano/out/test-image/` for slot-B rollback.
