#cloud-config
# Ubuntu 24.04 autoinstall. Rendered by templatefile() in ubuntu-rn.pkr.hcl and written
# onto a CD labelled 'cidata'; subiquity finds it through cloud-init's NoCloud datasource.
#
# Keep this minimal: only what is needed to reach an SSH prompt. Everything else is
# faster and far easier to iterate on as a provisioner script.
autoinstall:
  version: 1

  locale: en_US.UTF-8
  keyboard:
    layout: us

  # The installer's own network config; the image gets DHCP on the DevSwitch.
  #
  # Match BOTH naming schemes. This section replaces whatever netplan the live environment
  # was using, so a match that hits nothing takes the network down mid-install - and the
  # first thing to need it is apt, which fails with curtin exit status 100 on "retrieving
  # unzip". Hyper-V's synthetic NIC arrives over VMBus with no PCI slot for systemd to
  # build a predictable name from, so it stays "eth0" and never matches "en*" alone.
  network:
    version: 2
    ethernets:
      any-en:
        match:
          name: "en*"
        dhcp4: true
      any-eth:
        match:
          name: "eth*"
        dhcp4: true

  storage:
    # "direct" uses the whole disk. Do not use the lvm layout here: it caps the root LV
    # and leaves most of the disk stranded as free VG space, which the SDK build then
    # runs out of.
    layout:
      name: direct

  identity:
    hostname: ${hostname}
    username: dev
    password: "${dev_password_hash}"

  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "${ssh_public_key}"

  packages:
    - openssh-server
    - curl
    - ca-certificates
    - unzip
    - python3
    # hv_kvp_daemon. Without it the guest never reports its IP back over the Hyper-V KVP
    # channel, Get-VMNetworkAdapter shows an empty IPAddresses, and the hyperv-iso builder -
    # which finds the guest by reading exactly that field - waits out ssh_timeout on a VM
    # that is up and reachable the whole time. A minimal server install does not pull it in;
    # the kernel's hv_utils module (heartbeat) is not the same thing.
    - linux-cloud-tools-virtual

  # Always double-quote these. A shell command is not a YAML scalar: an unquoted one that
  # contains ": " makes the parser read it as a mapping, and a single bad line invalidates
  # the WHOLE document - cloud-init then loads nothing, subiquity finds no autoinstall
  # config, and the VM sits on the interactive installer with a perfectly good seed CD
  # mounted. The failure is silent apart from a "Failed loading yaml blob" warning in
  # `cloud-init status --long`.
  #
  # Do NOT pin cloud-init's datasource_list here. The installer applies `identity` and `ssh`
  # by way of a first-boot cloud-init run in the target; forcing datasource_list to [NoCloud,
  # None] makes that run read the still-attached cidata CD - i.e. THIS autoinstall document,
  # which has no `users:` - instead of the installer's own user/SSH seed. The image then
  # comes up with no dev user, no authorized_keys, and password auth still on, and Packer
  # cannot log in. The clone-boot optimisation that pin was meant to provide now lives in
  # 90-cleanup.sh, which runs after first boot and so only affects clones.
  late-commands:
    - "echo 'dev ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-dev"
    - "chmod 440 /target/etc/sudoers.d/90-dev"

  shutdown: reboot
