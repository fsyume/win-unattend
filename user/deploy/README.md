# user\deploy\ —— 首次登录时下发给客户机的文件

这个目录下的文件由 iVentoy 内置的 HTTP 服务对外提供，客户机在首次登录时按下面的地址取回：

```
http://<iVentoy 服务器 IP>:16000/user/deploy/<文件名>
```

## 你需要放进来的东西

| 文件 | 必需 | 说明 |
|---|---|---|
| `install-drivers.cmd` | ✅ | 本仓库提供，**原样复制过来**，不要改文件名 |
| 驱动总裁安装包 | ✅ | 从 https://www.sysceo.com/software-softwarei-id-258.html 下载，**重命名为 `DrvCeoSetup.exe`** |

## 为什么安装包要改名

`unattend.xml` 里的 `FirstLogonCommands` 写死了这个地址：

```
http://$$VT_SERVER_IP$$:$$VT_HTTP_PORT$$/user/deploy/DrvCeoSetup.exe
```

（`$$...$$` 由 iVentoy 在每台客户机上展开成实际 IP 和端口。）

URL 里带中文在 HTTP 层需要转义，容易出错，所以**统一用 ASCII 文件名**。想用别的名字也可以，改
`unattend.xml` 里那处 URL 即可。

## 注意事项

- **目录名和文件名都不要有中文或空格**（iVentoy 的硬性要求，官方文档明确写过）。
- 路径必须正好是 `<iVentoy 解压目录>\user\deploy\`，**不能有中文或空格**，否则整套都跑不起来。
- 安装包比较大（几十 MB），这只是局域网传输，不影响装机速度。
- 驱动总裁运行起来后**还需要访问公网**去下载驱动，所以客户机要能上网。

## 排查

客户机上的日志：

```
C:\Windows\Temp\install-drivers.log
```

脚本退出后仍留在 `C:\Windows\Temp\install-drivers.cmd`，现场可以手动再跑一次：

```cmd
C:\Windows\Temp\install-drivers.cmd http://<服务器IP>:16000/user/deploy/DrvCeoSetup.exe
```

浏览器里直接打开那个 URL 也能验证 iVentoy 是否正常提供文件。
