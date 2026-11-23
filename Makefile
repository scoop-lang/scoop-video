TARGET := $(shell uname -m | sed 's/arm64/aarch64/')-apple-darwin
TOOLCHAIN ?= $(shell scoop-install show | sed -n 's/^Root: //p')
SKIA_LIB ?= $(TOOLCHAIN)/lib/$(TARGET)/libscoop_skia.a
SKIA_HEADERS ?= $(firstword $(wildcard $(TOOLCHAIN)/lib/$(TARGET)/include/skia ../scoop/sysroot/lib/$(TARGET)/include/skia))
FLAGS := -std=c++20 -O2 -g -Wall -Wextra -Werror -fobjc-arc -DSK_RELEASE -DSK_METAL
FRAMEWORKS := -framework AppKit -framework AVFoundation -framework CoreVideo -framework CoreMedia -framework IOSurface -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics -framework Foundation -lz

.PHONY: all
all: build/nv12-probe

.PHONY: ui
ui:
	@mkdir -p build
	scoop build -p scoop:scoop-video-ui --release --keep-symbols -o build/scoop-video-ui

build/nv12-probe: probes/skia/main.mm probes/skia/Renderer.mm probes/skia/Renderer.h $(SKIA_LIB)
	@test -f "$(SKIA_HEADERS)/include/gpu/ganesh/SkImageGanesh.h" || { echo "Set SKIA_HEADERS to the matching Skia header root"; exit 1; }
	mkdir -p build
	xcrun clang++ $(FLAGS) -I"$(SKIA_HEADERS)" probes/skia/main.mm probes/skia/Renderer.mm "$(SKIA_LIB)" $(FRAMEWORKS) -o $@

.PHONY: audit
audit: build/cpu-access.dylib build/audit-control

build/blit-audit.dylib: scripts/blit-audit.m
	@mkdir -p build
	xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -dynamiclib $< -framework Foundation -framework CoreVideo -framework Metal -o $@

build/cpu-access.dylib: scripts/cpu-access.m
	mkdir -p build
	xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -dynamiclib $< -framework Foundation -framework CoreVideo -framework IOSurface -framework Metal -framework VideoToolbox -o $@

build/audit-control: scripts/audit-control.m
	mkdir -p build
	xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc $< -framework Foundation -framework CoreVideo -framework IOSurface -framework Metal -framework VideoToolbox -o $@
