#!/bin/sh
set -eu

source_file="$(dirname "$0")/../PortEntry.m"
grep -Fq "window.__afGiftAutoTapResult='';" "$source_file"
grep -Fq "setTimeout(()=>probe(1),4000)" "$source_file"
grep -Fq "else if(confirm)done()" "$source_file"
