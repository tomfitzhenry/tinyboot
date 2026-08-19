# Runs tboot-loader as PID 1 of an armv7 qemu virt machine (software
# emulation) and kexecs the same kernel + a tiny initrd from a BLS fat drive.
# The kexec'd initrd prints HELLO-FROM-KEXECD-INITRD, which the check asserts.
#
# The kernel is a standard multi_v7_defconfig build plus three qemu-virt /
# zig adjustments below, exercising src/kexec/arm.zig end to end, including
# the FDT round trip (fdt.zig) against qemu's real device tree (8-byte-aligned
# memory reservation block, 2-cell linux,initrd-* properties).
{
  tboot,
  tinybootNative,
  zig,
  pkgs,
  stdenvNoCC,
}:

let
  cross = pkgs.pkgsCross.armv7l-hf-multiplatform;

  kernel = (cross.buildLinux {
    version = pkgs.linuxKernel.kernels.linux_6_6.version;
    src = pkgs.linuxKernel.kernels.linux_6_6.src;
    defconfig = "multi_v7_defconfig";
    kernelPatches = [ ];
    ignoreConfigErrors = true;
    enableCommonConfig = false;
    autoModules = false;
    structuredExtraConfig = with pkgs.lib.kernel; {
      # The qemu virt DTB's PCI MEM64 window (0x8000000000..) overflows a
      # 32-bit phys_addr_t and makes pci-host-generic fail probe without
      # LPAE.
      ARM_LPAE = yes;
      # multi_v7_defconfig enables DEVTMPFS_MOUNT; tboot-loader mounts
      # devtmpfs itself and would fail with EBUSY.
      DEVTMPFS_MOUNT = no;
      # multi_v7_defconfig lacks NEON; zig emits NEON instructions
      # (compiler_rt memcpy) and the kernel SIGILLs without it.
      NEON = yes;
    };
  }).overrideAttrs (o: {
    buildFlags = [ "zImage" ];
    outputs = [ "out" ];
    installPhase = ''
      mkdir -p $out
      cp arch/arm/boot/zImage $out/zImage
    '';
  });

  # tiny /init for the kexec'd kernel: a freestanding zig binary that prints
  # HELLO-FROM-KEXECD-INITRD on the console.
  init = pkgs.stdenvNoCC.mkDerivation {
    name = "tinyboot-arm32-hello-init";
    dontUnpack = true;
    nativeBuildInputs = [ zig ];
    ZIG_GLOBAL_CACHE_DIR = "$TMPDIR";
    buildPhase = ''
      zig build-exe -target arm-linux -OReleaseSmall ${./init.zig} -femit-bin=$out
    '';
  };

  # tiny initrd for the kexec'd kernel: the init above, packed with
  # tboot-initrd (the project's own cpio tool, zstd-compressed like the
  # tboot-loader initrd itself).
  initrd = pkgs.stdenvNoCC.mkDerivation {
    name = "tinyboot-arm32-hello-initrd";
    dontUnpack = true;
    nativeBuildInputs = [ tinybootNative ];
    buildPhase = ''
      tboot-initrd -i ${init} -o $out
    '';
  };

  # fat drive for the qemu guest: BLS type #1 entry pointing at the
  # kernel + initrd.
  drive = pkgs.stdenvNoCC.mkDerivation {
    name = "tinyboot-arm32-drive";
    dontUnpack = true;
    buildPhase = ''
      mkdir -p $out/loader/entries
      cp ${kernel}/zImage $out/zImage
      cp ${initrd} $out/initrd
      cat > $out/loader/loader.conf <<'EOF'
      timeout 0
      default tinyboot-*
      EOF
      cat > $out/loader/entries/tinyboot-1.conf <<'EOF'
      title Tinyboot
      linux /zImage
      initrd /initrd
      options console=ttyAMA0
      architecture arm
      EOF
    '';
    installPhase = "true";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "check-tinyboot-arm32";
  dontUnpack = true;
  passthru = { inherit kernel init initrd drive; };
  buildInputs = [ pkgs.qemu ];
  buildCommand = ''
    mkdir -p drive
    cp -r ${drive}/. drive/.

    # -cpu max: like runner.zig; zig's arm baseline emits instructions
    # (e.g. idiv) the virt machine's default cortex-a15 lacks.
    qemu-system-arm -machine virt -m 512M -cpu max \
      -kernel ${kernel}/zImage \
      -initrd ${tboot}/${tboot.passthru.initrdFile} \
      -drive if=virtio,format=raw,file=fat:rw:$PWD/drive \
      -nographic -append "console=ttyAMA0" > serial.log 2> qemu-stderr.log &
    QPID=$!
    result=1
    for i in $(seq 1 400); do
      if grep -q "HELLO-FROM-KEXECD-INITRD" serial.log; then result=0; break; fi
      if ! kill -0 $QPID 2>/dev/null; then break; fi
      sleep 0.25
    done
    kill $QPID 2>/dev/null || true
    wait $QPID 2>/dev/null || true
    echo "=== serial log ==="
    cat serial.log
    if [ $result -ne 0 ]; then
      echo "FAIL: did not see HELLO-FROM-KEXECD-INITRD" >&2
      exit 1
    fi
    mkdir -p $out
    cp serial.log $out/serial.log
  '';
}
