# Thin wrapper: every target is a build.sh subcommand.
.PHONY: help build kernel initramfs bootimg export-patches check clean

help:
	@./build.sh

build: kernel initramfs bootimg

kernel:
	./build.sh linux

initramfs:
	./build.sh initramfs

bootimg:
	./build.sh bootimg

export-patches:
	./build.sh export-patches

check:
	./build.sh check

clean:
	./build.sh clean
