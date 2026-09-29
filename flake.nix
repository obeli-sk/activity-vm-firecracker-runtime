{
  description = "Firecracker activity VM runtime for Obelisk";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e158d9ed9b51c98974c5e66e1ba1c9e0255fecaa";
    bochs-runtime.url = "github:obeli-sk/activity-vm-bochs-runtime/d8e3d71965f01b4a2b63b4d84af8d37eecda137f";
  };

  outputs = { nixpkgs, bochs-runtime, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      bochsPackages = bochs-runtime.packages.${system};
      # Firecracker boots an uncompressed ELF kernel, attaches devices over virtio-mmio,
      # shares the Nix closure as an erofs drive and the mailbox over vsock.
      kernel = bochsPackages.linux.overrideAttrs (old: {
        postPatch = old.postPatch + ''
          scripts/config --file .config \
            -e HYPERVISOR_GUEST -e PARAVIRT -e KVM_GUEST \
            -e VSOCKETS -e VIRTIO_VSOCKETS \
            -e EROFS_FS \
            -e SMP --set-val NR_CPUS 64 \
            -e MEMORY_HOTPLUG -e MEMORY_HOTPLUG_DEFAULT_ONLINE -e MEMORY_HOTREMOVE \
            -e MHP_MEMMAP_ON_MEMORY -e STRICT_DEVMEM -e VIRTIO_MEM
        '';
        buildPhase = ''
          runHook preBuild
          make "''${makeFlagsArray[@]}" olddefconfig
          make "''${makeFlagsArray[@]}" -j"$NIX_BUILD_CORES" vmlinux
          runHook postBuild
        '';
        postBuild = ''
          for option in KVM_GUEST VIRTIO_VSOCKETS EROFS_FS SMP VIRTIO_MEM VIRTIO_MMIO_CMDLINE_DEVICES; do
            grep -qx "CONFIG_$option=y" .config
          done
        '';
        installPhase = ''
          install -D -m 644 vmlinux "$out/vmlinux"
          install -D -m 644 .config "$out/config"
        '';
      });
      mailbox = pkgs.pkgsStatic.runCommandCC "mailbox" { } ''
        mkdir -p $out/bin
        $CC -O2 -Wall -Werror -o $out/bin/mailbox ${./mailbox.c}
      '';
      runtime = pkgs.runCommand "activity-vm-firecracker-runtime" {
        src = ./.;
        nativeBuildInputs = [ pkgs.bash pkgs.libarchive pkgs.gzip ];
      } ''
        bash "$src/build-bundle.sh" \
          ${pkgs.firecracker}/bin/firecracker \
          ${kernel}/vmlinux \
          ${bochsPackages.rootfs}/rootfs.bin \
          ${mailbox}/bin/mailbox \
          ${pkgs.erofs-utils}/bin/mkfs.erofs \
          "$out"
      '';
    in {
      packages.${system} = {
        inherit runtime mailbox kernel;
        firecracker = pkgs.firecracker;
        rootfs = bochsPackages.rootfs;
        default = runtime;
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.bash pkgs.libarchive pkgs.gzip pkgs.jq pkgs.curl pkgs.erofs-utils pkgs.firecracker ];
      };
    };
}
