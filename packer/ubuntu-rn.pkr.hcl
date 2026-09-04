# Golden image for React Native development VMs (section 8.1 of linux-vm-on-windows.md).
#
# Builds Ubuntu 24.04 + XFCE + Android SDK + a pre-booted AVD snapshot + Claude Code,
# then generalizes the disk so New-DevVM.ps1 can clone it with differencing disks.
#
#   packer init  .
#   packer build .
#
# Must run from an ELEVATED shell: the Hyper-V builder needs Administrator.

packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

# ------------------------------------------------------------------ inputs ---

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso"
}

variable "iso_checksum" {
  type        = string
  description = "sha256 of the ISO; from https://releases.ubuntu.com/24.04/SHA256SUMS"
  default     = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
}

variable "vm_name" {
  type    = string
  default = "golden-ubuntu-rn"
}

variable "output_directory" {
  type        = string
  description = "Packer writes an exported VM here; Build-GoldenImage.ps1 lifts the VHDX out of it."
  default     = "C:/Hyper-V/golden/build"
}

variable "switch_name" {
  type    = string
  default = "DevSwitch"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

variable "ssh_timeout" {
  type        = string
  description = "How long to wait for the installed system to answer on SSH. This is also how long a failed boot command sits on the installer's language menu before Packer gives up, so keep it tight: a healthy autoinstall is up in about 10 minutes."
  default     = "25m"
}

variable "dev_password_hash" {
  type = string
  # SHA-512 crypt of the CONSOLE password for the dev user - default plaintext is "devvm".
  # This only ever matters at the Hyper-V console (Ctrl+Alt+F2 during a build, or a login
  # prompt on a wedged VM): SSH is key-only, since the autoinstall sets ssh.allow-pw: false.
  # A known default is deliberate - the previous one had no recorded plaintext, which is
  # exactly why a broken build could not be logged into to debug.
  #   Change it with:  openssl passwd -6
  #   then pass -var "dev_password_hash=<hash>" or edit this default.
  description = "SHA-512 crypt hash of the dev console password. Default plaintext: devvm."
  default     = "$6$devvmsalt$GiZ0v.02kBs634mGUoPSfSZvj6o1VqntatWSQsOG7oAoywqLTvd5zMLBfAp.vQcwb5osyEazd.9ZzY1vtYI8X1"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type        = number
  description = "MB. Static: nested virtualization forbids dynamic memory."
  default     = 8192
}

variable "disk_size" {
  type        = number
  description = "MB. The whole toolchain plus a booted AVD snapshot needs ~35 GB; 60 leaves room."
  default     = 61440
}

# Toolchain versions. Bump these to rebuild the image on an upgrade (section 12).
variable "android_api" {
  type    = number
  default = 35
}

variable "android_build_tools" {
  type    = string
  default = "35.0.0"
}

variable "android_cmdline_tools_url" {
  type    = string
  default = "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
}

variable "avd_name" {
  type    = string
  default = "dev"
}

variable "avd_device" {
  type    = string
  default = "pixel_6"
}

variable "avd_ram_mb" {
  type    = number
  default = 4096
}

variable "node_major" {
  type    = number
  default = 22
}

variable "watchman_version" {
  type        = string
  description = "GitHub release tag to pin. Empty (the default) resolves the newest release that ships a linux zip; watchman is optional and a failure here only warns."
  default     = ""
}

# ------------------------------------------------------------------ seed ---

locals {
  user_data = templatefile("${path.root}/http/user-data.pkrtpl.hcl", {
    ssh_public_key    = trimspace(file(pathexpand(var.ssh_public_key_path)))
    dev_password_hash = var.dev_password_hash
    hostname          = var.vm_name
  })

  # A guard, not plumbing. If the rendered document is not valid YAML, cloud-init loads
  # NOTHING - not a partial config, nothing - subiquity finds no autoinstall section, and
  # the build spends its whole ssh_timeout parked on the interactive installer with a
  # perfectly good seed CD attached. The only trace is a "Failed loading yaml blob" line in
  # `cloud-init status --long`, inside a VM Packer deletes on the way out.
  #
  # yamldecode() turns exactly that into a `packer validate` failure, in a second, before
  # anything boots. Reading .autoinstall.version also catches a document that parses but
  # lost its top-level key.
  autoinstall_version = yamldecode(local.user_data).autoinstall.version
}

# ----------------------------------------------------------------- builder ---

source "hyperv-iso" "ubuntu" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  vm_name          = var.vm_name
  output_directory = var.output_directory
  switch_name      = var.switch_name

  generation         = 2
  enable_secure_boot = false

  cpus      = var.cpus
  memory    = var.memory
  disk_size = var.disk_size

  # The build VM boots the Android emulator itself (40-emulator-snapshot.sh), so it needs
  # nested virtualization - which in turn requires static memory. Without these two lines
  # the build dies at the last provisioner with "KVM is not available".
  enable_virtualization_extensions = true
  enable_dynamic_memory            = false
  enable_mac_spoofing              = true

  # Autoinstall config on a second CD labelled "cidata"; templated so the SSH key is injected
  # rather than committed. cloud-init's NoCloud datasource finds it by volume label, so the
  # boot command carries no URL and no datasource argument at all.
  #
  # This replaced http_content + a ds=nocloud-net;s=http://... argument typed into GRUB, which
  # had two silent failure modes: the ";" needs escaping GRUB may or may not honour, and the
  # guest has to reach Packer's HTTP server through the Windows firewall on an external switch.
  # Either one just lands you on the installer's language menu. Packer builds this ISO with
  # oscdimg (Windows ADK); Build-GoldenImage.ps1 puts it on PATH.
  cd_label = "cidata"
  cd_content = {
    "user-data" = local.user_data
    "meta-data" = "instance-id: ${var.vm_name}\nlocal-hostname: ${var.vm_name}\n"
  }

  # Timing here is the single most fragile part of the build, and its failure mode is the
  # one that looks like "the script doesn't work": if these keystrokes miss, GRUB's countdown
  # expires, the ISO boots its default entry with no `autoinstall` on the kernel command line,
  # and subiquity starts its INTERACTIVE installer - language, keyboard, storage, profile.
  # Nothing in this build ever answers those screens; Packer just waits for SSH until
  # ssh_timeout. Sitting on the installer means the boot command failed, not that the build
  # wants input. See "The installer is asking me questions" in README.md.
  #
  # Start typing early and press <esc> three times: whenever the menu turns up inside that
  # window one of them lands on it and stops the countdown, and the extras are harmless -
  # <esc> at a GRUB menu with no submenu does nothing.
  boot_wait = "3s"
  # Hyper-V's synthetic keyboard drops characters when Packer types at full speed, and a
  # mangled "autoinstall" is indistinguishable from no autoinstall at all. Slow the groups
  # down, keep the typed line short, and pace individual keys with PACKER_KEY_INTERVAL -
  # Build-GoldenImage.ps1 sets it (-KeyInterval) because it has no template equivalent.
  boot_keygroup_interval = "250ms"
  boot_command = [
    "<esc><wait2><esc><wait2><esc><wait2>",
    "c<wait2>",
    "linux /casper/vmlinuz autoinstall ---<enter><wait2>",
    "initrd /casper/initrd<enter><wait2>",
    "boot<enter>"
  ]

  communicator         = "ssh"
  ssh_username         = "dev"
  ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  # Long enough for the install plus first boot on a slow disk, short enough that a failed
  # boot command costs minutes rather than an hour. A healthy build reaches SSH in ~10.
  ssh_timeout = var.ssh_timeout

  shutdown_command = "sudo -S shutdown -P now"
  shutdown_timeout = "15m"
}

# ------------------------------------------------------------- provisioners ---

build {
  sources = ["source.hyperv-iso.ubuntu"]

  # Scripts run as the unprivileged dev user and sudo where they must: the Android SDK,
  # the AVD and the Claude config all belong to dev, not to root.
  provisioner "shell" {
    script          = "${path.root}/scripts/10-desktop-xrdp.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/20-node-java.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "NODE_MAJOR=${var.node_major}",
      "WATCHMAN_VERSION=${var.watchman_version}",
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/25-ide-browser.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/30-android-sdk.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "ANDROID_API=${var.android_api}",
      "ANDROID_BUILD_TOOLS=${var.android_build_tools}",
      "CMDLINE_TOOLS_URL=${var.android_cmdline_tools_url}",
      "AVD_NAME=${var.avd_name}",
      "AVD_DEVICE=${var.avd_device}",
      "AVD_RAM_MB=${var.avd_ram_mb}",
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/40-emulator-snapshot.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "AVD_NAME=${var.avd_name}",
    ]
    timeout = "30m"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/50-claude.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "AVD_NAME=${var.avd_name}",
    ]
  }

  # Last: everything after this point would put machine identity back on the disk.
  provisioner "shell" {
    script          = "${path.root}/scripts/90-cleanup.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
