#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

echo "开始 DIY2 配置……"
echo "========================="

function merge_package(){
    repo=`echo $1 | rev | cut -d'/' -f 1 | rev`
    pkg=`echo $2 | rev | cut -d'/' -f 1 | rev`
    # find package/ -follow -name $pkg -not -path "package/custom/*" | xargs -rt rm -rf
    git clone --depth=1 --single-branch $1
    mv $2 package/custom/
    rm -rf $repo
}
function drop_package(){
    find package/ -follow -name $1 -not -path "package/custom/*" | xargs -rt rm -rf
}
function merge_feed(){
    if [ ! -d "feed/$1" ]; then
        echo >> feeds.conf.default
        echo "src-git $1 $2" >> feeds.conf.default
    fi
    ./scripts/feeds update $1
    ./scripts/feeds install -a -p $1
}
rm -rf package/custom; mkdir package/custom


# ARM64: Add CPU model name in proc cpuinfo
#wget -P target/linux/generic/pending-5.4 https://github.com/immortalwrt/immortalwrt/raw/master/target/linux/generic/hack-5.4/312-arm64-cpuinfo-Add-model-name-in-proc-cpuinfo-for-64bit-ta.patch
# autocore
sed -i 's/DEPENDS:=@(.*/DEPENDS:=@(TARGET_bcm27xx||TARGET_bcm53xx||TARGET_ipq40xx||TARGET_ipq806x||TARGET_ipq807x||TARGET_mvebu||TARGET_rockchip||TARGET_armvirt) \\/g' package/lean/autocore/Makefile
# Add cputemp.sh
#cp -rf $GITHUB_WORKSPACE/PATCH/new/script/cputemp.sh ./package/base-files/files/bin/cputemp.sh


#添加额外软件包
merge_package https://github.com/ophub/luci-app-amlogic luci-app-amlogic

# 晶晨宝盒
sed -i "s|https.*/amlogic-s9xxx-openwrt|https://github.com/breakingbadboy/OpenWrt|g" package/custom/luci-app-amlogic/luci-app-amlogic/root/etc/config/amlogic
sed -i "s|http.*/library|https://github.com/breakingbadboy/OpenWrt|g" package/custom/luci-app-amlogic/luci-app-amlogic/root/etc/config/amlogic
sed -i "s|s9xxx_lede|ARMv8|g" package/custom/luci-app-amlogic/luci-app-amlogic/root/etc/config/amlogic
#sed -i "s|.img.gz|..OPENWRT_SUFFIX|g" package/custom/luci-app-amlogic/luci-app-amlogic/root/etc/config/amlogic


# Optimization level -Ofast
if [ "$platform" = "x86_64" ]; then
    curl -s https://raw.githubusercontent.com/sbwml/r4s_build_script/master/openwrt/patch/target-modify_for_x86_64.patch | patch -p1
fi

# x86 - disable intel_pstate
sed -i 's/noinitrd/noinitrd intel_pstate=disable/g' target/linux/x86/image/grub-efi.cfg

# bash
sed -i 's#ash#bash#g' package/base-files/files/etc/passwd
sed -i 's#ash#bash#g' package/base-files/files/etc/shells
sed -i 's#\\u@\\h:\\w\\\$#\\[\\e[32;1m\\][\\u@\\h\\[\\e[0m\\] \\[\\033[01;34m\\]\\W\\[\\033[00m\\]\\[\\e[32;1m\\]]\\[\\e[0m\\]\\\$#g' package/base-files/files/etc/profile
mkdir -pv files/root
curl -so files/root/.bash_profile https://raw.githubusercontent.com/sbwml/r4s_build_script/master/openwrt/files/root/.bash_profile
curl -so files/root/.bashrc https://raw.githubusercontent.com/sbwml/r4s_build_script/master/openwrt/files/root/.bashrc
sed -i 's/^eval/#eval/g' files/root/.bashrc


./scripts/feeds update -a
./scripts/feeds install -a

echo "========================="
echo " DIY2 配置完成……"
