# arm-gh-runner

On-demand, ephemeral ARM64 GitHub Actions runners on AWS EC2, built on NixOS
with Determinate Nix and deployed with OpenTofu. The runner set is
parameterized: each deployment serves any list of GitHub repositories via a
single `repos` variable.

The instance boots a Determinate Systems NixOS AMI, applies the baseline
NixOS closure published to FlakeHub (`Fifty-Nine/aws-gh-runner/0.1`), then
switches locally to a generated overlay flake that materializes one GitHub
Actions runner per repository in `repos`. Runners register with the labels
`arm64` and `nixos`; target them from workflows with `runs-on: [arm64,
nixos]`.

## Deployment

### 1. GitHub: create a fine-grained PAT

1. In GitHub, go to **Settings → Developer settings → Personal access
   tokens → Fine-grained tokens → Generate new token**.
2. Set **Repository access** to **Only select repositories** and choose
   every repository you intend to pass in `repos`.
3. Under **Repository permissions**, grant **Administration: Read and
   write** (required to register runners). **Metadata: Read-only** is
   granted implicitly.
4. Set a short expiration — the token is only used at runner registration
   time.
5. Copy the token; you will store it in Secrets Manager below.

### 2. FlakeHub: create a flakehub token

1. Sign in at [flakehub.com](https://flakehub.com) and open your settings.
2. Create a token under **Tokens**. The instance uses it to
   authenticate `determinate-nixd` so it can pull the baseline closure from
   the FlakeHub cache.
3. Copy the token; you will store it in Secrets Manager below.

### 3. AWS: secrets and IAM

Configure the AWS CLI against the target account and region:

```shell
aws configure   # region: us-west-2 unless overridden
```

Create the two secrets the instance reads at boot:

```shell
aws secretsmanager create-secret --name github-runner/pat \
  --secret-string 'ghp_xxxxxxxxxxxxxxxxxxxx'

aws secretsmanager create-secret --name github-runner/flakehub-token \
  --secret-string 'fh-token-xxxxxxxxxxxxxxxxxxxxx'
```

Create the instance role and profile so the instance can fetch those
secrets via its IAM credentials:

```shell
aws iam create-role --role-name gh-runner-instance-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

aws iam put-role-policy --role-name gh-runner-instance-role \
  --policy-name gh-runner-secrets \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": [
        "arn:aws:secretsmanager:*:*:secret:github-runner/pat-*",
        "arn:aws:secretsmanager:*:*:secret:github-runner/flakehub-token-*"
      ]
    }]
  }'

aws iam create-instance-profile --instance-profile-name gh-runner-instance-role
aws iam add-role-to-instance-profile \
  --instance-profile-name gh-runner-instance-role \
  --role-name gh-runner-instance-role
```

Your *deployment* IAM user (the one running `tofu`) needs the permissions in
[`ec2-builder-policy.json`](ec2-builder-policy.json). Attach it as a user
policy; it scopes EC2 lifecycle and networking management to the runner
instance types and requires `iam:PassRole` on
`arn:aws:iam::<account>:role/gh-runner-instance-role` — replace the
hardcoded account ID `821522070788` with your own.

### 4. OpenTofu

Create `terraform.tfvars` (gitignored) listing the SSH key pair name in the
target region and the repositories to serve:

```hcl
ssh_key_name = "my-personal-ssh-key"
repos        = ["User/Repo.git", "User/MyOtherRepo.git"]
```

Other variables:

- `volume_size` — root volume in GiB (default `20`). The default includes
  headroom for the swapfile below; increase further if the volume is also
  holding large store paths.
- `swap_size_gib` — swapfile provisioned on the root volume, in GiB
  (default `4`; set `0` to disable). Recommended for memory-constrained
  t4g instances; the build tier sets `0` since it has ample RAM.

Apply using one of the supplied profiles from [`profiles/`](profiles/):

| Profile             | Tier                                                 | Root volume | Indicative cost |
| ------------------- | ---------------------------------------------------- | ----------- | --------------- |
| `warm-nano.tfvars`  | Cache-pull only; cannot compile                      | 20 GiB      | ~$6.77/mo       |
| `warm-small.tfvars` | Cache pulls and lightweight builds                   | 20 GiB      | ~$15.90/mo      |
| `build.tfvars`      | Full-power cold-cache compilation; run transiently   | 80 GiB      | ~$15/day        |

The warm profiles use the default 4 GiB swapfile; the build profile
disables swap.

You can use infracost to get updated estimates.

```shell
tofu init
tofu apply -var-file=profiles/warm-small.tfvars
```

On first boot the instance logs into FlakeHub, applies the baseline closure,
and switches to the per-repo overlay. When it converges, `tofu output
ssh_command` gives SSH access and the runners appear (registered, possibly
after a brief delay) under each repository's **Settings → Actions →
Runners**.

The generated overlay flake applies the baseline module published to
FlakeHub (`Fifty-Nine/aws-gh-runner/0.1`). When updating this repository's
module (e.g. after a NixOS option change), let the GitHub Actions workflow
publish the new FlakeHub release before running `tofu apply`; provisioning
against an unpublished module fails with an unknown-option error.

Tearing down removes the VPC, subnet, and instance; the Secrets Manager
secrets and IAM role persist for reuse.

## Changing the runner set

Edit `repos` in `terraform.tfvars` and re-run `tofu apply`. Repo changes
replace the instance (`user_data_replace_on_change`), so all repos are
reprovisioned together. The PAT must remain scoped to every repository in
the list.
