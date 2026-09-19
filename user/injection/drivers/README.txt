把客户端网卡的 .inf / .sys / .cat 驱动文件放进这个目录（可以有子目录，
iVentoy 和 pnputil 都会递归查找）。

user\injection\ 下的所有内容会被打成一个压缩包（.7z），并在 iVentoy 网页界面里
设为该 ISO 的「注入文件」。iVentoy 会在 setup.exe 运行之前把它解压到 ISO 那个
WinPE 的 X:\ 下，所以 X:\drivers 一定存在，unattend.xml 里的 DriverPaths
配置也才成立。

注意：即使没有驱动，也要把这个目录保留在压缩包里——
正是这个空目录让 X:\drivers 得以存在。

需要收集哪些驱动：
  - Intel：   PROSet / "Intel Ethernet Adapter Complete Driver Pack"
             （含 e1000e、i40e、ice、igb、ixgbe 等），这个包覆盖了大多数板载网卡
  - Broadcom：NetXtreme / NetXtreme-E（bnxt）
  - Mellanox：WinOF-2（mlx5），服务器上很常见
  - Realtek： RTL8111/8168/8125（rt640x64.inf），台式机和笔记本上很常见
  - Marvell/Aquantia：aqnic（很多 AM5 和消费级主板上的板载 10G 网卡）

这里只需要 Windows x64 的、且属于 WinPE / boot 类别的那份驱动；
不需要完整的安装程序，只要解压出来带 .inf 的那个驱动目录即可。
