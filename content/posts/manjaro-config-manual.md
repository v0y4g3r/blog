---
title: "Manjaro 配置指南"
date: 2018-04-03T5:58:37+08:00
draft: false
toc: false
images:
tags: 
  - Linux
---

Manjaro 是基于 ArchLinux 的发行版, 既具备了开箱即用的用户友好性, 又继承了 ArchLinux 滚动更新的特性和内容丰富的 AUR 软件包, 并且内置了 MHWD ,方便用户管理硬件驱动. Manjaro 具有GNOME/i3/xfce/KDE等多种图形界面可供选择. 以下是 Manjaro with KDE 的基本配置选项.

## 1 更换与更新源

```
#nano /etc/pacman.d/mirrors/China
[China]
Server = http://mirrors.ustc.edu.cn/manjaro/$branch/$repo/$arch

#nano /etc/pacman-mirrors.conf
OnlyCountry=China
pacman-mirrors -g

# /etc/pacman.conf 
[archlinuxcn]
SigLevel = Optional TrustedOnly
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch

sudo pacman -Syy && sudo pacman -S archlinuxcn-keyring
```

## 2 安装中文输入法

```
sudo yaourt -S fcitx-sogoupinyin
sudo yaourt -S fcitx-im # 全部安装
sudo yaourt -S fcitx-configtool # 图形化配置工具
```

在`~/.xprofile`文件当中输入(如果没有就创建)

```
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS="@im=fcitx"
```

## 3 安装其他常用软件

```
yaourt -S visual-studio-code
yaourt -S vim git zsh 
```

### 录屏转GIF

```
yaourt -S peek
```

### 截图

```
yaourt -S xclip deepin-screenshot
```

注意upstream的`deepin-screenshot`自动复制到剪贴板的功能有问题, 需要将文件`/usr/share/deepin-screenshot/src/gtk-clip`的内容修改为

```
#!/bin/bash
# REPLACE EXISTING FILE WITH THIS
# /usr/share/deepin-screenshot/src/gtk-clip
# source: http://unix.stackexchange.com/a/266761
command -v xclip >/dev/null 2>&1 || { echo "Need command xclip. Aborting." >&2; exit 1; }
[[ -f "$1" ]] || { echo "Error: Not a file." >&2; exit 1; }
TYPE=$(file -b --mime-type "$1")
xclip -selection clipboard -t "$TYPE" < "$1"
```

## 4 修改Splash Screen

替换`/usr/share/plasma/look-and-feel/org.kde.<theme>.desktop/contents/components/artwork`下面的`background.png`即可

## 5 强制Libreoffice使用GTK主题

```
sudo vim /etc/profile.d/libreoffice-still.sh
```

取消`export SAL_USE_VCLPLUGIN=gtk3`这一行的注释 `System Settings` -> `Application Style` -> `Gnome Application Style` -> `Select GTK3 Style`选择`Breath` `System Settings` -> `Colors` -> Uncheck `Apply Colors for Non-Qt Applications`