#!/usr/bin/env python3
"""
Durable AWS infrastructure for the Cyclone V build.

Deploys only things that cost nothing while idle. Everything that costs money --
the instance -- is created and destroyed per build by ../build-ec2.py.

    cd infra/cdk
    python3 -m venv .venv && . .venv/bin/activate
    pip install -r requirements.txt
    cdk bootstrap          # once per account/region
    cdk deploy

Idle cost after this is the AMI's EBS snapshot, roughly $3-5/month. Destroying
the stack does not delete the AMI; see bake-ami.sh.

Two design choices worth stating, because both remove things the plan asked for:

No inbound SSH, and no key pair. UserData does the whole build and pushes the
results to S3, so nothing ever needs to connect *to* the instance. A security
group with an SSH rule is a standing hole guarding a door nobody uses. The cost
is that a failed build cannot be poked at live -- which is why the build log is
uploaded unconditionally, success or failure, as the first thing the script
looks at.

No VPC. The default VPC's public subnet is used. Creating one means either a NAT
gateway at ~$32/month, which dwarfs every other cost here, or a private subnet
the instance cannot reach S3 from without an endpoint. Neither is worth it for a
job that runs for fifteen minutes and dies.
"""

import aws_cdk as cdk
from aws_cdk import (
    Stack,
    aws_ec2 as ec2,
    aws_iam as iam,
    aws_s3 as s3,
    aws_ssm as ssm,
)
from constructs import Construct


class QuartusBuildStack(Stack):
    def __init__(self, scope: Construct, cid: str, **kw):
        super().__init__(scope, cid, **kw)

        # Sources in, bitstreams and reports out. Old artifacts expire on their
        # own: a .sof is a few megabytes and there is no reason to keep every
        # build ever made, but there is also no reason to make deleting them a
        # thing anyone has to remember.
        bucket = s3.Bucket(
            self, "ArtifactBucket",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            encryption=s3.BucketEncryption.S3_MANAGED,
            versioned=False,
            lifecycle_rules=[
                s3.LifecycleRule(
                    id="expire-build-artifacts",
                    prefix="builds/",
                    expiration=cdk.Duration.days(30),
                ),
                s3.LifecycleRule(
                    id="abort-incomplete-uploads",
                    abort_incomplete_multipart_upload_after=cdk.Duration.days(1),
                ),
            ],
            # The Quartus installer lives here too and is tedious to re-fetch,
            # so the bucket survives a stack destroy on purpose.
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )

        # The instance's identity. Scoped to this bucket and nothing else -- the
        # build has no business reading any other bucket in the account.
        role = iam.Role(
            self, "BuildRole",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            description="Cyclone V build instance: this bucket only",
        )
        bucket.grant_read_write(role)

        # Lets the instance terminate itself if the shutdown path is ever
        # changed to an API call rather than `shutdown -h`. Cheap to grant, and
        # its absence is an annoying thing to debug at 2am.
        role.add_to_policy(iam.PolicyStatement(
            actions=["ec2:TerminateInstances"],
            resources=["*"],
            conditions={"StringEquals": {"ec2:ResourceTag/Project": "rv32-de1soc"}},
        ))

        profile = iam.CfnInstanceProfile(
            self, "BuildInstanceProfile", roles=[role.role_name])

        # Egress only. Nothing connects inward; see the module docstring.
        vpc = ec2.Vpc.from_lookup(self, "DefaultVpc", is_default=True)
        sg = ec2.SecurityGroup(
            self, "BuildSg", vpc=vpc, allow_all_outbound=True,
            description="Cyclone V build: egress only, no inbound",
        )

        # Where build-ec2.py looks things up, so the launcher needs no arguments
        # and no hardcoded account-specific strings.
        ssm.StringParameter(self, "BucketParam",
                           parameter_name="/rv32-de1soc/bucket",
                           string_value=bucket.bucket_name)
        ssm.StringParameter(self, "ProfileParam",
                            parameter_name="/rv32-de1soc/instance-profile",
                            string_value=profile.ref)
        ssm.StringParameter(self, "SgParam",
                            parameter_name="/rv32-de1soc/security-group",
                            string_value=sg.security_group_id)
        ssm.StringParameter(self, "SubnetParam",
                            parameter_name="/rv32-de1soc/subnet",
                            string_value=vpc.public_subnets[0].subnet_id)

        # Written by bake-ami.sh rather than here, because the AMI is baked once
        # by hand and must outlive any `cdk destroy`. A placeholder so the
        # parameter exists and the launcher's error message can be specific.
        ssm.StringParameter(self, "AmiParam",
                            parameter_name="/rv32-de1soc/ami",
                            string_value="UNSET-run-bake-ami.sh")

        cdk.CfnOutput(self, "Bucket", value=bucket.bucket_name)
        cdk.CfnOutput(self, "NextStep",
                      value="bake the Quartus AMI: infra/bake-ami.sh")


app = cdk.App()
QuartusBuildStack(
    app, "Rv32De1SocBuild",
    # from_lookup needs a concrete account and region rather than a synth-time
    # placeholder, so this stack is deliberately environment-specific.
    env=cdk.Environment(
        account=app.node.try_get_context("account") or None,
        region=app.node.try_get_context("region") or None,
    ),
    description="Ephemeral Quartus builds for the RV32 DE1-SoC port",
)
app.synth()
