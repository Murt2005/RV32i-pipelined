#!/usr/bin/env python3
"""
Run one Quartus compile on an ephemeral spot instance, then bring it down.

    python3 infra/build-ec2.py                 # build fpga/de1soc, fetch the .sof
    python3 infra/build-ec2.py --keep-alive    # leave it up to investigate a failure
    python3 infra/build-ec2.py --dry-run       # print the plan, launch nothing

Roughly $0.04 a build: a c7i.2xlarge spot is about $0.11-0.15/hour and the
compile is fifteen minutes. Idle cost between builds is the AMI snapshot alone.

The instance is told to destroy itself three ways, because the failure that
actually costs money is an instance nobody noticed:

  - InstanceInitiatedShutdownBehavior=terminate, so `shutdown -h` is fatal
  - `shutdown -h +45` armed *before* the build starts, so a hung Quartus dies
  - the UserData script's exit trap shuts down on any error, not just success

Belt and braces on purpose. A forgotten c7i.2xlarge is about $70/month.

Requires: pip install boto3, and credentials with permission to run instances.
`cdk deploy` must have run once, and infra/bake-ami.sh once, before this works.
"""

import argparse
import io
import os
import subprocess
import sys
import tarfile
import time

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    sys.exit("boto3 not installed:  pip install boto3")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARAMS = ("bucket", "instance-profile", "security-group", "subnet", "ami")

# UserData. Runs as root on boot, and every path out of it powers the machine
# off. $-signs that must survive to the remote shell are escaped as $$ below by
# .format()-free string substitution -- this is a plain % template on purpose.
USERDATA = r"""#!/bin/bash
set -uo pipefail

BUCKET="%(bucket)s"
KEY="%(key)s"
LOG=/tmp/build.log

# Armed before anything else can hang. A Quartus compile that wedges still costs
# only 45 minutes rather than until someone looks at the console.
shutdown -h +45 &

finish() {
  rc=$?
  # The log goes up unconditionally. With no inbound SSH this is the only
  # window into a failed build, so it must not be conditional on success.
  aws s3 cp "$LOG" "s3://$BUCKET/$KEY/build.log" || true
  echo "$rc" > /tmp/rc
  aws s3 cp /tmp/rc "s3://$BUCKET/$KEY/rc" || true
  %(keepalive)s
  shutdown -h now
}
trap finish EXIT

{
  echo "=== fetching sources ==="
  cd /tmp
  aws s3 cp "s3://$BUCKET/$KEY/src.tar.gz" src.tar.gz
  mkdir -p src && tar xzf src.tar.gz -C src
  cd src/fpga/de1soc

  echo "=== quartus_sh --flow compile ==="
  export PATH=/opt/intelFPGA_lite/quartus/bin:$PATH
  quartus_sh --flow compile rv32_de1soc

  echo "=== uploading artifacts ==="
  aws s3 cp output_files/rv32_de1soc.sof "s3://$BUCKET/$KEY/rv32_de1soc.sof"
  # The reports are the point of a remote build you cannot watch: fit, timing
  # and any critical warnings. Uploaded individually so a missing one is
  # obvious rather than silently absent from a tarball.
  for r in .fit.rpt .sta.rpt .map.rpt .flow.rpt; do
    f="output_files/rv32_de1soc$r"
    [ -f "$f" ] && aws s3 cp "$f" "s3://$BUCKET/$KEY/$(basename $f)"
  done
} >> "$LOG" 2>&1
"""


def ssm_params(ssm):
    out = {}
    for p in PARAMS:
        try:
            out[p] = ssm.get_parameter(Name=f"/rv32-de1soc/{p}")["Parameter"]["Value"]
        except ClientError:
            sys.exit(f"missing SSM parameter /rv32-de1soc/{p} -- run `cdk deploy` first")
    if out["ami"].startswith("UNSET"):
        sys.exit("no Quartus AMI yet -- run infra/bake-ami.sh once (see its header)")
    return out


def make_source_tarball():
    """Only what Quartus needs, and only what git knows about.

    Deliberately not a tar of the working tree: build/ alone is hundreds of
    megabytes including a 64 MB snapshot, and uploading it on every build would
    cost more time than the compile saves.
    """
    files = subprocess.run(
        ["git", "-C", REPO, "ls-files",
         "*.sv", "*.v", "*.sdc", "*.qsf", "*.qpf", "*.tcl", "*.qip"],
        capture_output=True, text=True, check=True).stdout.split()
    if not files:
        sys.exit("no HDL files found -- is fpga/de1soc/ committed?")

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for f in files:
            tf.add(os.path.join(REPO, f), arcname=f)
    buf.seek(0)
    return buf, len(files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--instance-type", default="c7i.2xlarge")
    ap.add_argument("--on-demand", action="store_true",
                    help="skip the spot request; ~4x the cost, no interruption")
    ap.add_argument("--keep-alive", action="store_true",
                    help="do not shut down after the build (costs money; "
                         "terminate it yourself)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--timeout", type=int, default=3600)
    args = ap.parse_args()

    ec2 = boto3.client("ec2")
    s3 = boto3.client("s3")
    p = ssm_params(boto3.client("ssm"))

    key = f"builds/{time.strftime('%Y%m%d-%H%M%S')}"
    tarball, nfiles = make_source_tarball()

    print(f"bucket   {p['bucket']}")
    print(f"key      {key}")
    print(f"ami      {p['ami']}")
    print(f"type     {args.instance_type}"
          f"{'  (on-demand)' if args.on_demand else '  (spot)'}")
    print(f"sources  {nfiles} files, {len(tarball.getvalue())/1e6:.2f} MB")
    if args.dry_run:
        print("\n--dry-run: nothing launched")
        return 0

    s3.upload_fileobj(tarball, p["bucket"], f"{key}/src.tar.gz")

    userdata = USERDATA % {
        "bucket": p["bucket"],
        "key": key,
        "keepalive": ("echo 'keep-alive: not shutting down'; sleep infinity"
                      if args.keep_alive else ""),
    }

    spec = dict(
        ImageId=p["ami"], InstanceType=args.instance_type,
        MinCount=1, MaxCount=1,
        IamInstanceProfile={"Arn": p["instance-profile"]},
        NetworkInterfaces=[{
            "DeviceIndex": 0, "SubnetId": p["subnet"],
            "Groups": [p["security-group"]],
            "AssociatePublicIpAddress": True,
        }],
        UserData=userdata,
        InstanceInitiatedShutdownBehavior="terminate",
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Project", "Value": "rv32-de1soc"},
                     {"Key": "Name", "Value": f"quartus-{key.split('/')[-1]}"}],
        }],
        BlockDeviceMappings=[{
            "DeviceName": "/dev/sda1",
            "Ebs": {"VolumeSize": 80, "VolumeType": "gp3",
                    "DeleteOnTermination": True},
        }],
    )
    if not args.on_demand:
        spec["InstanceMarketOptions"] = {
            "MarketType": "spot",
            "SpotOptions": {"SpotInstanceType": "one-time",
                            "InstanceInterruptionBehavior": "terminate"},
        }

    iid = ec2.run_instances(**spec)["Instances"][0]["InstanceId"]
    print(f"\nlaunched {iid}; polling s3://{p['bucket']}/{key}/rc")
    print("(the instance terminates itself; ^C here does not leave it running)")

    deadline = time.time() + args.timeout
    while time.time() < deadline:
        try:
            rc = int(s3.get_object(Bucket=p["bucket"],
                                   Key=f"{key}/rc")["Body"].read().strip())
            break
        except ClientError:
            time.sleep(15)
    else:
        print(f"\ntimed out after {args.timeout}s. The instance shuts itself "
              f"down; check s3://{p['bucket']}/{key}/build.log")
        return 1

    outdir = os.path.join(REPO, "build", "de1soc")
    os.makedirs(outdir, exist_ok=True)
    got = []
    for name in ("rv32_de1soc.sof", "build.log", "rv32_de1soc.fit.rpt",
                 "rv32_de1soc.sta.rpt", "rv32_de1soc.map.rpt"):
        try:
            s3.download_file(p["bucket"], f"{key}/{name}",
                             os.path.join(outdir, name))
            got.append(name)
        except ClientError:
            pass

    print(f"\nexit {rc}; fetched {', '.join(got) or 'nothing'} -> {outdir}")
    if rc != 0:
        print(f"build FAILED -- read {outdir}/build.log")
    return rc


if __name__ == "__main__":
    sys.exit(main())
