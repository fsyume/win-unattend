Put the .inf / .sys / .cat driver files for your client NIC models in this
folder (sub-folders are fine, iVentoy and pnputil both recurse).

Everything under user\injection\ gets packed into ONE archive (.7z) and that
archive is set as the ISO's "Injection File" in the iVentoy web UI. iVentoy
unpacks it into X:\ of the ISO's WinPE before setup.exe runs, so X:\drivers
is always present and the DriverPaths entry in unattend.xml stays valid.

Keep this folder in the archive even if it is empty - an empty directory is
what makes X:\drivers exist.

Which drivers to collect:
  - Intel:   PROSet / "Intel Ethernet Adapter Complete Driver Pack" (e1000e,
             i40e, ice, igb, ixgbe ...) - the pack covers most onboard NICs
  - Broadcom: NetXtreme / NetExtreme-E (bnxt)
  - Mellanox: WinOF-2 (mlx5) - common on servers
  - Realtek: RTL8111/8168/8125 (rt640x64.inf) - common on desktops/laptops
  - Marvell/Aquantia: aqnic (10G onboard on many AM5/consumer boards)

Only the Windows x64 driver of the *WinPE / boot* variant matters here; you do
not need the full installer, just the extracted driver folder with the .inf.
