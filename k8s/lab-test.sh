#!/bin/sh
# RUN ONE .walk LEG BY HAND, ON A POD THAT HAS /dev/kvm.
#
#   k8s/lab-test.sh fedora-workstation ssh /tmp/w/linux/fedora-workstation/steps/ssh.walk
#
# WHY THIS EXISTS SEPARATELY FROM lab-run.sh: that script resolves `/walks/<os>-<leg>.yaml` by a
# naming convention the repository no longer uses - the files are `.walk` now, and a leg under test
# is usually a WORKING COPY at /tmp/w, not the mounted /walks. This takes the walkthrough path as an
# argument, so a file can be tested before it is committed.
#
# IT DOES NOT START A DAEMON. The pod runs `easyvm serve --work /work` as PID 1 (k8s/lab.yaml), and
# one daemon runs every leg: `stop` ends a run, `destroy` clears a sandbox, and the server stays.
# Starting a second one is what put two of them in one pod and failed the next boot on a busy port.
#
# THE DISK IS TAKEN FROM /disks/pulled AND COPIED IN, because the daemon always boots /work/disk.qcow2.
set -eu

os=${1:?os, e.g. fedora-workstation}
leg=${2:?leg, e.g. ssh}
walk=${3:?path to the .walk file}

src=""
for f in "/disks/pulled/$os.qcow2" "/disks/pulled/distro.qcow2" "/disks/os/$os/install.qcow2" "/disks/os/$os/setup.qcow2"; do
    [ -f "$f" ] && { src="$f"; break; }
done
[ -n "$src" ] || { echo "=== no disk for $os; looked in /disks/pulled and /disks/os/$os" >&2; exit 1; }
echo "=== parent disk: $src"

# THE BINARY IS A PARAMETER, because the pod's image may predate the `.walk` parser and running the
# leg through it would test the old code - measured: `yaml: line 4: mapping values are not allowed`,
# which is the OLD loader refusing a file the new one reads.
EV=${EV:-easyvm}
echo "=== client: $EV ($($EV check "$walk" 2>&1 | head -1))"

echo "=== stop anything in progress"
$EV stop --work /work >/dev/null 2>&1 || true
sleep 3
$EV destroy --work /work >/dev/null 2>&1 || true
sleep 2
ip link del qemutap0 2>/dev/null || true

# THIS SCRIPT DOES NOT START, STOP OR REPLACE THE DAEMON, BECAUSE THERE IS EXACTLY ONE PER CONTAINER.
#
# `k8s/lab.yaml` runs `easyvm serve --work /work` as PID 1 with `restartPolicy: Always`, and the
# kubelet is what restarts it - that is the only reset that cannot leave a half-killed daemon behind.
#
# MEASURED, AND IT IS WHY THIS COMMENT EXISTS: an earlier version of this script killed whatever
# `easyvm` it found and started its own. In a pod whose PID 1 was `sleep infinity` that produced a
# daemon nobody supervised, and on a second run it produced TWO: the second answered
#
#	FAILED: http listen :8080: listen tcp :8080: bind: address already in use
#
# and the walk then ran against the first one, which was a different binary. The steps were answered by
# a server that did not know the vocabulary under test, and every conclusion drawn from that run was
# about the wrong build.
#
# SO THE BINARY UNDER TEST COMES FROM THE IMAGE. Rebuild it with `image.yml`, then restart the pod so
# the kubelet brings up the new one:
#
#	gh workflow run image.yml -f push=true
#	kubectl delete pod <name>        # the Deployment recreates it on the new :latest
#
# A LOCAL OVERRIDE IS STILL POSSIBLE and is opt-in: pass EV to point the CLIENT at another binary. The
# server is always the pod's own.

echo "=== copy the parent in"
rm -f /work/disk.qcow2
cp "$src" /work/disk.qcow2

# THE PASSWORD IS A RUN FACT, NOT A FILE FACT, AND OMITTING IT COST THIS HARNESS EVERY SSH STEP.
#
# `Executor.Password` comes from the REQUEST (`req.Password`), not from the walkthrough's own
# `password:` header - the file declares the value a stage uses for `sudo`, and the request supplies
# what the daemon should authenticate with. Without `--password` the engine dialled sshd with an
# EMPTY password, and every `require_ssh:` reported
#
#	the port is open but no shell answers: ssh: unable to authenticate
#
# on a guest whose password, `su`, `sudo` and `pam_unix` were all correct. MEASURED on openSUSE: the
# same `guest.Dial` with the password hardcoded returned `OK out="vmuser" status=0` while the leg
# failed, and the only difference was this flag.
#
# IT DEFAULTS TO THE DISK'S OWN PASSWORD FOR THIS REPOSITORY, and can be overridden the same way as
# the binary:
#
#	PW=something-else k8s/lab-test.sh <os> <leg> <walk>
PW=${PW:-Qz7vLp2w}

echo "=== run $walk"
exec "$EV" run "$walk" --work /work --boot-disk /work/disk.qcow2 --password "$PW"
