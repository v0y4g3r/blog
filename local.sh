#! /bin/bash

sudo gsed -i 's/^.*local\.huanglei\.rocks//g' /etc/hosts && echo "$(ifconfig en0 | ggrep -Po '(?<=inet )\d+\.\d+\.\d+\.\d+') local.huanglei.rocks" | sudo tee -a /etc/hosts && hugo server  --disableFastRender --bind 0.0.0.0 --baseURL http://local.huanglei.rocks
