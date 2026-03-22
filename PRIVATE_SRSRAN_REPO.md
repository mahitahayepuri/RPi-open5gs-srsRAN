# Using a Private or Custom srsRAN Repository

This guide explains how to deploy the gNB from a custom fork of the
srsRAN Project -- for example, a student's modified gNB code hosted in a
private GitHub repository.

## How it works

Two Ansible variables control which repository is cloned and compiled:

| Variable | Default | Defined in |
|---|---|---|
| `srsran_source_repo` | `https://github.com/srsRAN/srsRAN_Project.git` | `group_vars/all.yml` |
| `srsran_source_version` | `release_24_10_1` | `group_vars/all.yml` |

These variables are used by **both** the gNB compile on the gNB Pi and
the Grafana dashboard clone on the core Pi, so a single override keeps
everything in sync.

## Quick start (one-time override)

Pass the repo and branch/tag via `-e` on the command line:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_source_repo=https://github.com/student/srsRAN_Project.git \
  -e srsran_source_version=my-feature-branch
```

This clones the student's fork, compiles the gNB, and deploys it --
without changing any files in the repo.

## Permanent override

Edit `group_vars/all.yml`:

```yaml
srsran_source_repo: "https://github.com/student/srsRAN_Project.git"
srsran_source_version: "my-feature-branch"
```

Then re-run the srsRAN playbook to trigger a fresh clone + full
recompile.

## Per-host override (inventory)

If different Pi pairs should build from different repos (e.g. one pair
on the official release, another on a student fork):

```ini
# inventory-pi5.ini
[gnb]
192.168.2.55 ansible_user=pi srsran_source_repo=https://github.com/student/srsRAN_Project.git srsran_source_version=my-branch
```

> **Note:** The Grafana clone on the core Pi reads `srsran_source_repo`
> from `group_vars/all.yml` (or `[all:vars]`), not from the `[gnb]`
> host vars.  To override Grafana as well, add the variable under
> `[all:vars]` in the inventory file or use `-e` on the command line.

## Private repository authentication

The playbooks clone over HTTPS by default.  For **private** repositories
Git needs credentials.  There are two options:

### Option A -- SSH URL with deploy key

1. Generate a deploy key on the gNB Pi (or copy one from your machine):

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/srsran_deploy -N ""
   ```

2. Add the public key (`~/.ssh/srsran_deploy.pub`) as a **deploy key**
   in the GitHub repository settings (read-only is sufficient).

3. Configure SSH on the Pi to use it for GitHub:

   ```
   # ~/.ssh/config on the Pi
   Host github.com
     IdentityFile ~/.ssh/srsran_deploy
     StrictHostKeyChecking accept-new
   ```

4. Use the SSH URL when overriding the repo:

   ```bash
   ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
     -e srsran_source_repo=git@github.com:student/srsRAN_Project.git \
     -e srsran_source_version=my-branch
   ```

### Option B -- HTTPS with a personal access token

1. Create a [GitHub personal access token](https://github.com/settings/tokens)
   with `repo` scope.

2. Embed the token in the URL:

   ```bash
   ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
     -e srsran_source_repo=https://TOKEN@github.com/student/srsRAN_Project.git \
     -e srsran_source_version=my-branch
   ```

   > **Security note:** The token will appear in the process list and
   > Ansible log output.  For classroom use this is acceptable; for
   > production use, prefer SSH keys.

## Grafana dashboard compatibility

The Grafana metrics stack (Telegraf, InfluxDB, Grafana) is cloned from
the same `srsran_source_repo` and `srsran_source_version`.  The
dashboards are generic and work with any gNB build, but if your fork
removes or restructures the `docker/` directory, the Grafana playbook
will fail.

If your fork doesn't include Grafana configs, you can skip the Grafana
play by limiting the run:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  --skip-tags grafana \
  -e srsran_source_repo=https://github.com/student/srsRAN_Project.git \
  -e srsran_source_version=my-branch
```

## srsUE (srsRAN 4G)

The srsUE binary is built from a separate repository (`srsRAN_4G`) with
its own variables:

| Variable | Default | Defined in |
|---|---|---|
| `srsue_source_repo` | `https://github.com/srsRAN/srsRAN_4G.git` | `group_vars/ue.yml` |
| `srsue_source_version` | `release_23_11` | `group_vars/ue.yml` |

Override the same way:

```bash
ansible-playbook -i inventory-pi5.ini srsue/playbooks/srsue.yml \
  -e srsue_source_repo=https://github.com/student/srsRAN_4G.git \
  -e srsue_source_version=my-ue-branch
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Clone hangs (no output) | Git prompting for credentials in non-interactive session | All git tasks set `GIT_TERMINAL_PROMPT=0`; check the error message and set up SSH or token auth |
| `fatal: repository not found` | Repo URL is wrong or private without credentials | Verify the URL and set up authentication (see above) |
| `fatal: Remote branch 'xxx' not found` | Branch/tag doesn't exist in the fork | Check available branches with `git ls-remote <repo-url>` |
| Grafana play fails | Student fork missing `docker/` directory | Skip with `--skip-tags grafana` or keep the docker dir in the fork |
