#!/usr/bin/env bash
#
# One-time: build the Quartus AMI that build-ec2.py launches.
#
# Run this once, by hand, on a throwaway instance. It takes an hour or two,
# almost all of it Quartus installing itself, and it is not automated because
# the installer download needs an Intel account and accepting a licence -- a
# step no script should be pretending to do on your behalf.
#
#   1. put the installer in S3 (from your machine, after logging in to Intel):
#        aws s3 cp Quartus-lite-23.1std.1.993-linux.tar \
#          s3://$BUCKET/installers/
#
#   2. launch a scratch instance: Ubuntu 22.04, c7i.2xlarge, 80 GB gp3,
#      the instance profile from `cdk deploy`, a key pair you hold
#
#   3. scp this script over, run it as root, then follow the tail
#
# Quartus Prime *Lite* specifically, and that is the load-bearing choice:
# Lite needs no licence file at all. Standard and Pro want a MAC-locked or
# floating licence, which is miserable on an instance whose MAC changes every
# launch. Lite supports Cyclone V SE (5CSEMA5F31C6); Pro does not support
# Cyclone V at all.
#
set -euo pipefail

BUCKET="${1:?usage: bake-ami.sh <artifact-bucket>}"
INSTALLER="${2:-Quartus-lite-23.1std.1.993-linux.tar}"
DEST=/opt/intelFPGA_lite

echo "=== dependencies ==="
# Quartus is a 32-bit-ish Java/Qt application in places and fails in obscure
# ways without these. libpng12 in particular: its absence shows up as the GUI
# installer exiting silently, which is a memorable afternoon.
dpkg --add-architecture i386
apt-get update
apt-get install -y --no-install-recommends \
    unzip tar libc6:i386 libncurses6:i386 libstdc++6:i386 \
    libxext6 libxft2 libxtst6 libx11-6 libfontconfig1 libsm6 \
    default-jre-headless awscli

echo "=== fetching installer ==="
mkdir -p /tmp/q && cd /tmp/q
aws s3 cp "s3://$BUCKET/installers/$INSTALLER" .
tar xf "$INSTALLER"

echo "=== installing (this is the slow part) ==="
# Unattended, and only the Cyclone V device family. Installing every family
# turns 8 GB into 40 and the AMI snapshot is the only standing cost here.
./setup*.run --mode unattended --unattendedmodeui none \
    --installdir "$DEST" \
    --accept_eula 1 \
    --disable-components quartus_help,modelsim_ase,modelsim_ae

echo "=== verifying the toolchain can see Cyclone V ==="
export PATH="$DEST/quartus/bin:$PATH"
quartus_sh --version
# A device family that is not installed fails at *fit* time, twenty minutes
# into a compile, rather than at setup. Better to find out here.
quartus_sh --tcl_eval "puts [get_part_list -family {Cyclone V}]" | head -3

cat >/etc/profile.d/quartus.sh <<EOF
export PATH=$DEST/quartus/bin:\$PATH
EOF

echo "=== cleaning before the snapshot ==="
rm -rf /tmp/q
apt-get clean
cloud-init clean --logs || true
rm -f /root/.bash_history

cat <<'EOF'

Done. Now, from your own machine:

    aws ec2 create-image --instance-id <this-instance> \
        --name rv32-quartus-lite-23.1 --no-reboot
    aws ssm put-parameter --name /rv32-de1soc/ami \
        --value ami-XXXXXXXX --type String --overwrite
    aws ec2 terminate-instances --instance-ids <this-instance>

The AMI outlives `cdk destroy` on purpose -- rebaking it is the one step here
that costs an hour rather than a minute.
EOF
