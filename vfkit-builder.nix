{
  nixpkgsCommit ? "ec942ba042dad5ef097e2ef3a3effc034241f011",
  pubkey ? "",
  idleMinutes ? 30,
}:
let
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsCommit}.tar.gz";
    sha256 = "01i5lznyfxyb5r7llscybv17nhbnb58p0wi62rag9jdagjwxm6a7";
  };
  pkgs = import nixpkgs { };

  guestNixos = import "${nixpkgs}/nixos" {
    configuration =
      { lib, pkgs, ... }:
      {
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.kernelParams = [
          "console=ttyAMA0"
          "console=hvc0"
        ];
        boot.initrd.availableKernelModules = [
          "virtio_pci"
          "virtio_blk"
          "virtio_scsi"
          "virtio_net"
          "virtio_console"
          "usb_storage"
          "sr_mod"
        ];
        networking.hostName = "nix-builder";
        networking.useDHCP = lib.mkDefault true;
        networking.firewall.allowedTCPPorts = [ 22 ];
        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "prohibit-password";
            PasswordAuthentication = false;
          };
        };
        users.users.root.openssh.authorizedKeys.keys = lib.optional (pubkey != "") pubkey;
        nix.settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          trusted-users = [
            "root"
            "@wheel"
          ];
          max-jobs = "auto";
          cores = 0;
          auto-optimise-store = true;
          extra-platforms = [ "x86_64-linux" ];
        };
        nix.gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 30d";
        };
        documentation.enable = false;
        documentation.nixos.enable = false;
        system.stateVersion = "26.05";

        fileSystems."/" = {
          device = "/dev/vda2";
          fsType = "ext4";
        };
        fileSystems."/boot" = {
          device = "/dev/vda1";
          fsType = "vfat";
          options = [ "umask=0077" ];
        };

        fileSystems."/run/rosetta" = {
          device = "rosetta";
          fsType = "virtiofs";
        };
        boot.binfmt.registrations.rosetta = {
          interpreter = "/run/rosetta/rosetta";
          fixBinary = true;
          wrapInterpreterInShell = false;
          matchCredentials = true;
          magicOrExtension = ''\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00'';
          mask = ''\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';
        };
        systemd.services.systemd-binfmt = {
          after = [ "run-rosetta.mount" ];
          requires = [ "run-rosetta.mount" ];
        };

        systemd.services.idle-shutdown = {
          serviceConfig.Type = "oneshot";
          path = [ pkgs.iproute2 ];
          script = ''
            if [ -n "$(ss -tnH state established '( sport = :22 )')" ]; then
              echo 0 > /run/idle-shutdown
              exit 0
            fi
            count=$(( $(cat /run/idle-shutdown 2>/dev/null || echo 0) + 1 ))
            echo "$count" > /run/idle-shutdown
            if [ "$count" -ge ${toString idleMinutes} ]; then
              systemctl poweroff
            fi
          '';
        };
        systemd.timers.idle-shutdown = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "1min";
          };
        };
      };
    system = "aarch64-linux";
  };

  nixos-iso =
    (pkgs.fetchurl {
      url = "https://releases.nixos.org/nixos/26.05/nixos-26.05.590.ec942ba042da/nixos-minimal-26.05.590.ec942ba042da-aarch64-linux.iso";
      sha256 = "2f8d56bbfdb6fcbb5d4fe9744e61f692c0bc3fc6d880678169a4c06d0f12d89d";
    }).overrideAttrs
      (old: {
        unsafeDiscardReferences = {
          out = true;
        };
      });

  sourceDir = pkgs.runCommand "builder-source" { } ''
    mkdir -p $out
    cp ${./vfkit-builder.nix} $out/default.nix
  '';

  installerExpect = pkgs.writeText "installer.expect" ''
    set vfkit  $env(EXPECT_VFKIT)
    set pubkey $env(EXPECT_PUBKEY)
    set logf   $env(EXPECT_LOG)
    set vargs  $env(EXPECT_ARGS)

    log_user 0
    log_file -a $logf
    set timeout 360

    eval spawn $vfkit $vargs

    set payload "mkdir -p /root/.ssh && printf '%s\\n' '$pubkey' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && systemctl start sshd && echo SSH-ENABLED-OK"

    set asroot 0
    expect {
      -re {root@nixos:~\]#}   { set asroot 1 }
      -re {nixos@nixos:~\]\$} { }
      -re {login:\s*$}        { send "nixos\r"; exp_continue }
      -re {[Pp]assword:\s*$}  { send "\r";     exp_continue }
      timeout                 { puts stderr "TIMEOUT waiting for installer shell"; exit 1 }
    }

    sleep 1
    if {$asroot} {
      send "bash -c \"$payload\"\r"
    } else {
      send "sudo bash -c \"$payload\"\r"
    }
    expect {
      -re {SSH-ENABLED-OK} { }
      timeout              { puts stderr "TIMEOUT enabling sshd" }
    }

    set timeout -1
    expect eof
  '';

  builder = pkgs.writeShellScriptBin "builder" ''
    set -euo pipefail

    if [ -z "''${SELF:-}" ]; then
      if [ -f "$0" ]; then
        SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
      else
        SELF="builder"
      fi
    fi
    VMDIR="''${VMDIR:-$HOME/.vfkit-linux-nix-builder}"
    DISK="''${DISK:-$VMDIR/disk.img}"
    DISK_SIZE="''${DISK_SIZE:-80g}"
    NVRAM_INSTALL="$VMDIR/efistore-installer.nvram"
    NVRAM_BOOT="$VMDIR/efistore.nvram"
    INSTALLED_FLAG="$VMDIR/.installed"
    CONSOLE_LOG="$VMDIR/installer-console.log"

    MAC="''${MAC:-52:54:00:6e:62:6c}"
    NCPU="$(sysctl -n hw.ncpu)"
    MEMTOTAL=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    CPUS="''${CPUS:-$(( NCPU > 2 ? NCPU - 2 : 1 ))}"
    MEM="''${MEM:-8192}"
    INSTALL_MEM="''${INSTALL_MEM:-$(( (MEMTOTAL-2048) < 8192 ? 8192 : ((MEMTOTAL-2048) > 12288 ? 12288 : MEMTOTAL-2048) ))}"

    if [ -z "''${PUBKEY_FILE:-}" ]; then
      if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
      elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        PUBKEY_FILE="$HOME/.ssh/id_rsa.pub"
      else
        echo "error: Could not find default SSH public key in ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub." >&2
        echo "Please set PUBKEY_FILE=... explicitly." >&2
        exit 1
      fi
    fi

    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

    bold() { printf '\033[1m%s\033[0m\n' "$*"; }
    info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
    err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
    die()  { err "$*"; exit 1; }

    vfkit_bin() {
      echo "${pkgs.vfkit}/bin/vfkit"
    }

    mac_bootpd() { awk -F: '{for(i=1;i<=NF;i++){o=$i;sub(/^0/,"",o);printf (i>1?":":"") o}}' <<<"$MAC"; }

    vm_ip() {
      local leases="/var/db/dhcpd_leases" want; want="$(mac_bootpd)"
      [ -f "$leases" ] || return 0
      awk -v want="$want" '
        found!="" {next}
        /ip_address=/ {ip=$0; sub(/.*ip_address=/,"",ip)}
        /hw_address=/ {hw=$0; sub(/.*hw_address=1,/,"",hw); if(hw==want) found=ip}
        END {print found}' "$leases"
    }

    ssh_vm() { local ip; ip="$(vm_ip)" || true; [ -n "''${ip:-}" ] || die "no VM IP (is it running?)"; ssh "''${SSH_OPTS[@]}" "root@$ip" "$@"; }

    wait_ssh() {
      local t="''${1:-300}" w=0 ip
      while [ "$w" -lt "$t" ]; do
        ip="$(vm_ip)" || true
        if [ -n "''${ip:-}" ] && ssh "''${SSH_OPTS[@]}" -o BatchMode=yes "root@$ip" true 2>/dev/null; then echo "$ip"; return 0; fi
        sleep 3; w=$((w+3))
      done
      return 1
    }

    vfkit_running() { pgrep -f "vfkit.*$DISK" >/dev/null 2>&1; }

    kill_vfkit() {
      pgrep -f "vfkit.*$DISK" >/dev/null 2>&1 || return 0
      pkill -f "vfkit.*$DISK" 2>/dev/null || true
      local w=0
      while pgrep -f "vfkit.*$DISK" >/dev/null 2>&1; do
        [ "$w" -ge 8 ] && pkill -9 -f "vfkit.*$DISK" 2>/dev/null || true
        sleep 1; w=$((w+1))
        [ "$w" -ge 15 ] && break
      done
    }

    ensure_disk() {
      [ -f "$DISK" ] && { info "Disk present"; return; }
      mkdir -p "$VMDIR"
      info "Creating sparse raw disk $DISK ($DISK_SIZE)"
      mkfile -n "$DISK_SIZE" "$DISK"
    }

    boot_installer_bg() {
      kill_vfkit; sleep 1
      rm -f "$NVRAM_INSTALL" "$DISK"
      mkfile -n "$DISK_SIZE" "$DISK"
      local pubkey; pubkey="$(grep -m1 . "$PUBKEY_FILE")" || die "no pubkey in $PUBKEY_FILE"
      : >"$CONSOLE_LOG"
      info "Booting installer (cpus=$CPUS mem=''${INSTALL_MEM}MiB) and enabling SSH …"
      EXPECT_VFKIT="$(vfkit_bin)" \
      EXPECT_PUBKEY="$pubkey" EXPECT_LOG="$CONSOLE_LOG" \
      EXPECT_ARGS="--cpus $CPUS --memory $INSTALL_MEM \
        --bootloader efi,variable-store=$NVRAM_INSTALL,create \
        --device virtio-blk,path=$DISK \
        --device usb-mass-storage,path=${nixos-iso},readonly \
        --device virtio-net,nat,mac=$MAC \
        --device virtio-serial,stdio --device virtio-rng" \
      ${pkgs.expect}/bin/expect -f "${installerExpect}" &
      EXPECT_PID=$!
    }

    do_install() {
      ensure_disk
      boot_installer_bg
      info "Waiting for installer SSH …"
      local ip
      if ! ip="$(wait_ssh 420)"; then
        err "installer never came up on SSH. Last console output:"; tail -20 "$CONSOLE_LOG" >&2 || true
        die "see $CONSOLE_LOG"
      fi
      info "Installer reachable at root@$ip — copying sources and building on VM …"
      ssh "''${SSH_OPTS[@]}" "root@$ip" "mkdir -p /tmp/builder-source"
      ${pkgs.gnutar}/bin/tar -C "${sourceDir}" -cf - . | ssh "''${SSH_OPTS[@]}" "root@$ip" "tar -xf - -C /tmp/builder-source"

      local pubkey; pubkey="$(grep -m1 . "$PUBKEY_FILE")" || die "no pubkey in $PUBKEY_FILE"

      local system_path
      system_path="$(ssh "''${SSH_OPTS[@]}" "root@$ip" "nix-build --no-out-link --argstr pubkey '$pubkey' -A system /tmp/builder-source/default.nix")"

      info "Partitioning and formatting /dev/vda on VM …"
      ssh "''${SSH_OPTS[@]}" "root@$ip" "
        set -euo pipefail
        printf 'label: gpt\nsize=512MiB, type=U\ntype=L\n' | sfdisk --wipe always /dev/vda
        udevadm settle
        mkfs.vfat -F 32 /dev/vda1
        mkfs.ext4 -F -L nixos /dev/vda2
        mount /dev/vda2 /mnt
        mkdir -p /mnt/boot
        mount /dev/vda1 /mnt/boot
        nixos-install --system '$system_path' --no-root-passwd --root /mnt
      "

      info "Install done — powering off installer."
      ssh "''${SSH_OPTS[@]}" "root@$ip" "poweroff" 2>/dev/null || true
      wait "''${EXPECT_PID:-0}" 2>/dev/null || true
      kill_vfkit
      touch "$INSTALLED_FLAG"
    }

    boot_builder() {
      [ -f "$INSTALLED_FLAG" ] || die "not installed yet — run: ./builder install"
      kill_vfkit
      local create=""; [ -f "$NVRAM_BOOT" ] || create=",create"
      local serial="virtio-serial,stdio"
      if [ ! -t 0 ] || [ ! -t 1 ]; then serial="virtio-serial,logFilePath=$VMDIR/console.log"; fi
      bold "Booting builder VM (cpus=$CPUS mem=''${MEM}MiB, mac=$MAC). Ctrl-C to stop."
      "$(vfkit_bin)" \
        --cpus "$CPUS" --memory "$MEM" \
        --bootloader "efi,variable-store=$NVRAM_BOOT$create" \
        --device "virtio-blk,path=$DISK" \
        --device "virtio-net,nat,mac=$MAC" \
        --device "rosetta,mountTag=rosetta" \
        --device "$serial" --device virtio-rng
    }

    boot_detached() {
      [ -f "$INSTALLED_FLAG" ] || die "not installed yet — run: ./builder install"
      vfkit_running && return 0
      nohup "$SELF" boot >/dev/null 2>&1 </dev/null &
      disown 2>/dev/null || true
    }

    ensure_installed() {
      ensure_disk
      [ -f "$INSTALLED_FLAG" ] || do_install
    }

    STARTED_BY_US=0
    ensure_running() {
      ensure_installed
      local ip; ip="$(vm_ip)"
      if [ -n "$ip" ] && ssh "''${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null; then return 0; fi
      if vfkit_running; then info "Builder is booting …"
      else info "Builder not running — starting it on demand …"; boot_detached; STARTED_BY_US=1; fi
      ip="$(wait_ssh 180)" || die "builder did not come up; see $VMDIR/console.log"
      info "Builder ready at $ip"
    }

    SSH_KEY="''${SSH_KEY:-$HOME/.ssh/id_ed25519}"

    builder_spec() {
      local ip; ip="$(vm_ip)"; [ -n "$ip" ] || die "no VM IP"
      local b64
      b64="$(ssh_vm 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $1" "$2}' | base64 | tr -d '\n')" \
        || die "could not read host key from builder"
      echo "ssh-ng://root@$ip aarch64-linux,x86_64-linux $SSH_KEY $CPUS 1 big-parallel,benchmark - $b64"
    }

    do_build() {
      ensure_running
      local spec; spec="$(builder_spec)"
      info "Building with remote builder: $spec"
      local rc=0
      nix-build "$@" --option builders "$spec" --option builders-use-substitutes true || rc=$?
      if [ "''${BUILDER_AUTOSTOP:-0}" = 1 ] && [ "$STARTED_BY_US" = 1 ]; then
        info "BUILDER_AUTOSTOP=1 → stopping builder"; kill_vfkit
      fi
      return $rc
    }

    status() {
      echo "vmdir:      $VMDIR"
      echo "iso:        ${nixos-iso}"
      echo "disk:       $([ -f "$DISK" ] && du -h "$DISK" | awk '{print $1" used"}' || echo missing)"
      echo "installed:  $([ -f "$INSTALLED_FLAG" ] && echo yes || echo no)"
      echo "vfkit:      $(vfkit_running && echo running || echo stopped)"
      echo "ip:         $(vm_ip || true)"
    }

    cmd="''${1:-up}"; shift || true
    case "$cmd" in
      up)
        ensure_running
        info "Builder is up. Use it with: ./builder build <args>   (or ./builder ssh)" ;;
      start)   ensure_running ;;
      install) do_install ;;
      boot)    boot_builder ;;
      build)   do_build "$@" ;;
      ssh)     ensure_running >/dev/null; ssh_vm "$@" ;;
      ip)      vm_ip ;;
      spec)    builder_spec ;;
      status)  status ;;
      stop)    kill_vfkit; info "stopped" ;;
      *) die "unknown command: $cmd (try: up start install boot build setup-offload ssh ip spec status stop)" ;;
    esac
  '';
in
builder // { system = guestNixos.system; }
