## SPDX-License-Identifier: MIT
##
## Copyright (c) 2018-2019 Andre Richter <andre.o.richter@gmail.com>

# Default to the RPi3
ifndef BSP
	BSP = rpi3
endif

# BSP-specific arguments
ifeq ($(BSP),rpi3)
	TARGET = aarch64-unknown-none-softfloat
	OUTPUT = kernel8.img
	QEMU_BINARY = qemu-system-aarch64
	QEMU_MACHINE_TYPE = raspi3
	QEMU_MISC_ARGS = -serial stdio
	OPENOCD_ARG = -f /openocd/tcl/interface/ftdi/olimex-arm-usb-tiny-h.cfg -f /openocd/rpi3.cfg
	JTAG_BOOT_IMAGE = jtag_boot_rpi3.img
	LINKER_FILE = src/bsp/rpi/link.ld
	RUSTC_MISC_ARGS = -C target-cpu=cortex-a53
else ifeq ($(BSP),rpi4)
	TARGET = aarch64-unknown-none-softfloat
	OUTPUT = kernel8.img
#	QEMU_BINARY = qemu-system-aarch64
#	QEMU_MACHINE_TYPE =
#	QEMU_MISC_ARGS = -serial stdio
	OPENOCD_ARG = -f /openocd/tcl/interface/ftdi/olimex-arm-usb-tiny-h.cfg -f /openocd/rpi4.cfg
	JTAG_BOOT_IMAGE = jtag_boot_rpi4.img
	LINKER_FILE = src/bsp/rpi/link.ld
	RUSTC_MISC_ARGS = -C target-cpu=cortex-a72
endif

SOURCES = $(wildcard **/*.rs) $(wildcard **/*.S) $(wildcard **/*.ld)

XRUSTC_CMD = cargo xrustc \
		--target=$(TARGET) \
		--features bsp_$(BSP) \
		--release \
		-- \
		-C link-arg=-T$(LINKER_FILE) \
		$(RUSTC_MISC_ARGS)

CARGO_OUTPUT = target/$(TARGET)/release/kernel

OBJCOPY_CMD = cargo objcopy \
		-- \
		--strip-all \
		-O binary

CONTAINER_UTILS   = rustembedded/osdev-utils

DOCKER_CMD        = docker run -it --rm
DOCKER_ARG_CURDIR = -v $(shell pwd):/work -w /work
DOCKER_ARG_TTY    = --privileged -v /dev:/dev
DOCKER_ARG_JTAG   = -v $(shell pwd)/../X1_JTAG_boot:/jtag
DOCKER_ARG_NET    = --network host

DOCKER_EXEC_QEMU         = $(QEMU_BINARY) -M $(QEMU_MACHINE_TYPE) -kernel $(OUTPUT)
DOCKER_EXEC_RASPBOOT     = raspbootcom
DOCKER_EXEC_RASPBOOT_DEV = /dev/ttyUSB0
# DOCKER_EXEC_RASPBOOT_DEV = /dev/ttyACM0

.PHONY: all doc qemu chainboot clippy clean readelf objdump nm

all: clean $(OUTPUT)

$(CARGO_OUTPUT): $(SOURCES)
	RUSTFLAGS="-D warnings -D missing_docs" $(XRUSTC_CMD)

$(OUTPUT): $(CARGO_OUTPUT)
	cp $< .
	$(OBJCOPY_CMD) $< $(OUTPUT)

doc:
	cargo xdoc --target=$(TARGET) --features bsp_$(BSP) --document-private-items
	xdg-open target/$(TARGET)/doc/kernel/index.html

ifeq ($(QEMU_MACHINE_TYPE),)
qemu:
	@echo "This board is not yet supported for QEMU."
else
qemu: all
	$(DOCKER_CMD) $(DOCKER_ARG_CURDIR) $(CONTAINER_UTILS) \
	$(DOCKER_EXEC_QEMU) $(QEMU_MISC_ARGS)
endif

chainboot: all
	$(DOCKER_CMD) $(DOCKER_ARG_CURDIR) $(DOCKER_ARG_TTY) \
	$(CONTAINER_UTILS) $(DOCKER_EXEC_RASPBOOT) $(DOCKER_EXEC_RASPBOOT_DEV) \
	$(OUTPUT)

jtagboot:
	$(DOCKER_CMD) $(DOCKER_ARG_TTY) $(DOCKER_ARG_JTAG) $(CONTAINER_UTILS) \
	$(DOCKER_EXEC_RASPBOOT) $(DOCKER_EXEC_RASPBOOT_DEV) \
	/jtag/$(JTAG_BOOT_IMAGE)

openocd:
	$(DOCKER_CMD) $(DOCKER_ARG_TTY) $(DOCKER_ARG_NET) $(CONTAINER_UTILS) \
	openocd $(OPENOCD_ARG)

define gen_gdb
	RUSTFLAGS="-D warnings -D missing_docs" $(XRUSTC_CMD) $1
	cp $(CARGO_OUTPUT) kernel_for_jtag
	$(DOCKER_CMD) $(DOCKER_ARG_CURDIR) $(DOCKER_ARG_NET) $(CONTAINER_UTILS) \
	gdb-multiarch -q kernel_for_jtag
endef

gdb: clean $(SOURCES)
	$(call gen_gdb,-C debuginfo=2)

gdb-opt0: clean $(SOURCES)
	$(call gen_gdb,-C debuginfo=2 -C opt-level=0)

clippy:
	cargo xclippy --target=$(TARGET) --features bsp_$(BSP)

clean:
	cargo clean

readelf:
	readelf -a kernel

objdump:
	cargo objdump --target $(TARGET) -- -disassemble -print-imm-hex kernel

nm:
	cargo nm --target $(TARGET) -- kernel | sort