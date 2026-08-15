#!/usr/bin/env bats
#
# Behaviour tests for the Claude Code env-guard PreToolUse hooks.
#
#   brew install bats-core
#   bats claude/tests/guards.bats
#
# Every case is a command an agent (Claude Code / CoWork) plausibly runs.
# `pass` = the hook stays silent and the command falls through to the normal
# permission flow. `ask` = the hook returns permissionDecision "ask".
#
# The rule under test: read-only inspection never prompts, anything that can
# change cluster/cloud/state always does — including when it is hidden inside
# a wrapper, a quoted `sh -c`, or an xargs pipeline.

bats_require_minimum_version 1.5.0

HOOK="${BATS_TEST_DIRNAME}/../hooks/env-guard.sh"

setup() {
  # Deterministic environment: no ambient cloud/context leaking into a case.
  unset OS_CLOUD OS_CLOUD_NAME KUBECONFIG ARGOCD_SERVER
  # Non-local fallback context for cases that omit --context, so a machine
  # whose current context is `orbstack` doesn't silently pass ask-cases.
  export KUBE_TEST_CONTEXT="wonka-factory"
}

# run_hook <command-string> — there is one hook; it dispatches to every profile.
run_hook() {
  local cmd="$1"
  run --separate-stderr env PATH="${BATS_TEST_DIRNAME}/stubs:$PATH" \
    "$HOOK" <<<"$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')"
}

assert_pass() { # <command>
  run_hook "$1"
  if [ -n "$output" ]; then
    echo "expected pass-through, hook asked:"
    echo "  cmd: $1"
    echo "  out: $output"
    return 1
  fi
}

assert_ask() { # <command>
  run_hook "$1"
  if ! printf '%s' "$output" | grep -q '"permissionDecision":"ask"'; then
    echo "expected ask, hook stayed silent:"
    echo "  cmd: $1"
    echo "  out: ${output:-<empty>}"
    return 1
  fi
}

# The prompt is what the human reads before approving, so for a command that
# names more than one target it is not enough that the hook asks — it has to
# name the environment the mutation actually lands in.
assert_reason() { # <command> <substring>
  run_hook "$1"
  if ! printf '%s' "$output" | grep -q -- "$2"; then
    echo "expected the prompt to name '$2':"
    echo "  cmd: $1"
    echo "  out: ${output:-<empty>}"
    return 1
  fi
}

# =============================================================================
# kubectl / helm — read-only work must never prompt
# =============================================================================

@test "helm: template render with a release literally named 'test'" {
  # The original false positive: `test` is the release name, not `helm test`.
  assert_pass \
    'helm template test chart --show-only templates/deployments/unicorn.yaml'
}

@test "helm: the full agent-style probe-inspection pipeline" {
  assert_pass \
    'pwd && (command -v helm >/dev/null && helm template test chart --show-only templates/deployments/unicorn.yaml 2>&1 | sed -n "/Probe/,/successThreshold/p" || echo "helm not installed")'
}

@test "helm: lint / show / diff / get / list / history / status" {
  assert_pass 'helm lint ./chart -f values-moonbase.yaml'
  assert_pass 'helm show values noodleshop/redis'
  assert_pass 'helm diff upgrade oompa ./chart --kube-context wonka-factory'
  assert_pass 'helm get values oompa -n oompa --kube-context wonka-factory'
  assert_pass 'helm list -A --kube-context wonka-factory -o json'
  assert_pass 'helm history oompa -n oompa --kube-context wonka-factory'
  assert_pass 'helm status oompa --kube-context wonka-factory'
}

@test "helm: values file named like a destructive verb" {
  assert_pass \
    'helm template oompa ./chart -f values-upgrade.yaml -f values-install.yaml'
}

@test "helm: local chart scaffolding and dependency work" {
  assert_pass 'helm create mychart'
  assert_pass 'helm dependency update ./chart'
  assert_pass 'helm repo add noodleshop https://charts.example.com/noodleshop'
}

@test "helm: dry-run upgrade" {
  assert_pass \
    'helm upgrade --install oompa ./chart --kube-context wonka-factory --dry-run'
}

@test "kubectl: get/describe/logs/top with verb-shaped names" {
  assert_pass 'kubectl --context wonka-factory get pods -l app=delete-me'
  assert_pass 'kubectl --context wonka-factory describe pod hamster-runner-1'
  assert_pass 'kubectl --context wonka-factory logs deploy/pancake-service --tail=100'
  assert_pass 'kubectl --context wonka-factory top pods -n oompa'
  assert_pass 'kubectl --context wonka-factory get svc -o jsonpath={.spec.clusterIP}'
}

@test "kubectl: rollout status/history are read-only" {
  assert_pass 'kubectl --context wonka-factory rollout status deploy/hamster-wheel -n oompa'
  assert_pass 'kubectl --context wonka-factory rollout history deploy/hamster-wheel'
}

@test "kubectl: diff, events, wait, auth can-i, explain, api-resources" {
  assert_pass 'kubectl --context wonka-factory diff -f manifests/'
  assert_pass 'kubectl --context wonka-factory events --for pod/squirrel-0'
  assert_pass 'kubectl --context wonka-factory wait --for=condition=Ready pod/squirrel-0'
  assert_pass 'kubectl --context wonka-factory auth can-i create deployments'
  assert_pass 'kubectl --context wonka-factory explain deployment.spec'
  assert_pass 'kubectl --context wonka-factory api-resources --namespaced=true'
}

@test "kubectl: client- and server-side dry runs" {
  assert_pass \
    'kubectl --context wonka-factory create deployment cupcake --image=nginx --dry-run=client -o yaml'
  assert_pass \
    'kubectl --context wonka-factory apply -f manifests/ --dry-run=server'
}

@test "kubectl: cp download out of a pod is a read" {
  assert_pass \
    'kubectl --context wonka-factory cp oompa/squirrel-0:/var/log/app.log ./app.log'
}

@test "kubectl: exec running a read-only command" {
  assert_pass 'kubectl --context wonka-factory exec deploy/hamster-wheel -- cat /etc/config.yaml'
  assert_pass 'kubectl --context wonka-factory exec -it squirrel-0 -n oompa -- env'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- ls -la /var/log'
}

@test "kubectl: kubeconfig-local operations and help" {
  assert_pass 'kubectl config get-contexts'
  assert_pass 'kubectl config current-context'
  assert_pass 'kubectl delete --help'
  assert_pass 'kubectl version --client'
}

@test "kubectl: destructive verbs on the local cluster" {
  assert_pass 'kubectl --context orbstack delete pod squirrel-0'
  assert_pass 'helm upgrade --install oompa ./chart --kube-context orbstack'
  assert_pass 'kubectl --context kind-dev apply -f manifests/'
}

@test "kubectl/helm: mentions that are not invocations" {
  assert_pass 'echo "run kubectl delete pod squirrel-0 to clean up"'
  assert_pass 'command -v helm >/dev/null && echo ok'
  assert_pass 'grep -r "helm upgrade" ./docs'
  assert_pass 'cat README.md | grep "kubectl apply"'
}

@test "kubectl: destructive verb only in a piped filter" {
  assert_pass \
    'kubectl --context wonka-factory get pods -o name | grep delete | wc -l'
}

# =============================================================================
# kubectl / helm — mutations must always prompt
# =============================================================================

@test "kubectl: core mutations on a non-local context" {
  assert_ask 'kubectl --context wonka-factory delete pod squirrel-0 -n oompa'
  assert_ask 'kubectl --context wonka-factory apply -f manifests/'
  assert_ask 'kubectl --context wonka-factory scale deploy/hamster-wheel --replicas=0'
  assert_ask 'kubectl --context wonka-factory patch svc web -p {"spec":{"type":"NodePort"}}'
  assert_ask 'kubectl --context wonka-factory drain node-1 --ignore-daemonsets'
  assert_ask 'kubectl --context wonka-factory create token waffle-bot'
}

@test "kubectl: rollout restart/undo mutate" {
  assert_ask 'kubectl --context wonka-factory rollout restart deploy/hamster-wheel -n oompa'
  assert_ask 'kubectl --context wonka-factory rollout undo deploy/hamster-wheel'
}

@test "kubectl: a boolean flag must not hide the verb" {
  assert_ask \
    'kubectl --context wonka-factory --insecure-skip-tls-verify delete pod squirrel-0'
}

@test "kubectl: --dry-run=none is not a dry run" {
  assert_ask 'kubectl --context wonka-factory apply -f manifests/ --dry-run=none'
}

@test "kubectl/helm: a dry run covers its own invocation only" {
  # The rehearse-then-do shape. Reading --dry-run off the whole command line
  # let the second, real, apply through on the first one's flag.
  assert_ask \
    'kubectl --context wonka-factory apply -f manifests/ --dry-run=server && kubectl --context wonka-factory apply -f manifests/'
  assert_ask \
    'helm upgrade oompa ./chart --kube-context wonka-factory --dry-run && helm upgrade oompa ./chart --kube-context wonka-factory'
}

@test "kubectl: a local segment does not vouch for a non-local one" {
  local cmd='kubectl --context orbstack apply -f local.yml && kubectl --context wonka-factory apply -f prod.yml'
  assert_ask "$cmd"
  assert_reason "$cmd" 'wonka-factory'
  # ...and two local segments still stay out of the way.
  assert_pass \
    'kubectl --context orbstack apply -f local.yml && kubectl --context orbstack delete pod squirrel-0'
}

@test "helm: --version picks a chart version, it is not a help request" {
  # `--version 1.2.3` selects what to ship. Treating it as `helm --version`
  # skipped classification and shipped it to production without a prompt.
  assert_ask \
    'helm --kube-context wonka-factory upgrade oompa chart --version 1.2.3'
  assert_ask \
    'helm upgrade --install oompa ./chart --kube-context wonka-factory --version 1.2.3'
  # The genuine article — first argument — still passes.
  assert_pass 'helm --version'
  assert_pass 'kubectl --version'
  assert_pass 'helm upgrade --help'
}

@test "kubectl: cp upload into a pod writes" {
  assert_ask 'kubectl --context wonka-factory cp ./patch.sh oompa/squirrel-0:/tmp/patch.sh'
}

@test "kubectl: exec with a shell or a write command" {
  assert_ask 'kubectl --context wonka-factory exec -it squirrel-0 -- sh'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- rm -rf /var/lib/data'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- bash -c "echo x > /etc/f"'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- psql -c "drop table t"'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- redis-cli FLUSHALL'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- find /data -name "*.log" -delete'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0'
}

@test "kubectl: exec find without a write action still reads" {
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- find /var/log -name "*.log"'
}

@test "kubectl: exec payload — allowlisted commands with a second personality" {
  # `env <cmd>` is arbitrary execution; the others set state rather than read it.
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- env FOO=1 rm -rf /data'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- env sh -c "rm -rf /"'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- hostname evil-box'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- date -s "2020-01-01"'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- date "2020-01-01"'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- ss -K dst 10.0.0.1'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- nvidia-smi --gpu-reset'
}

@test "kubectl: exec payload — the same commands without an operand still read" {
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- env'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- printenv'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- hostname'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- date -u'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- uname -a'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- df -h /data'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- du -sh /var/log'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- ss -tulpn'
}

@test "kubectl: exec payload — interpreters and clients are never allowlisted" {
  local c
  for c in sh bash zsh ash dash python python3 perl ruby node php psql mysql \
           mongosh redis-cli nc curl wget tee dd chmod chown kill apt apk; do
    assert_ask "kubectl --context wonka-factory exec squirrel-0 -- $c --version"
  done
}

@test "kubectl: exec payload — writer flags in assignment form" {
  # `--set=…` is the same flag as `--set …`; in a pod with CAP_SYS_TIME it
  # moves the clock. Matching only the bare token read it as a clock *read*.
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- date --set=2026-01-01'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- date --set-time=2026-01-01'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- find /var/log -delete'
  # Reading the clock and the filesystem is still a read.
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- date -u'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- find /var/log -name "*.log"'
}

@test "kubectl: piping into exec" {
  # Writing into the pod over stdin: the payload decides, and none of these are readers.
  assert_ask 'cat dump.sql | kubectl --context wonka-factory exec -i squirrel-0 -- psql'
  assert_ask 'cat script.sh | kubectl --context wonka-factory exec -i squirrel-0 -- sh'
  assert_ask 'echo bad | kubectl --context wonka-factory exec -i squirrel-0 -- tee /etc/passwd'
  assert_ask 'tar cf - ./payload | kubectl --context wonka-factory exec -i squirrel-0 -- tar xf - -C /'
  assert_ask 'kubectl --context wonka-factory exec squirrel-0 -- sh -c "cat /etc/x | rm -rf /data"'
  # Reading out of the pod and filtering locally stays read-only.
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- cat /var/log/app.log | grep -i error | tail -20'
  assert_pass 'kubectl --context wonka-factory exec squirrel-0 -- ps aux | sort -k3 -r | head'
}

@test "kubectl: auth reconcile writes RBAC" {
  assert_ask 'kubectl --context wonka-factory auth reconcile -f rbac.yaml'
}

@test "kubectl: custom kubeconfig is treated as non-local" {
  assert_ask 'kubectl --kubeconfig /tmp/kc.yaml delete pod squirrel-0'
  assert_ask 'KUBECONFIG=/tmp/kc.yaml kubectl delete pod squirrel-0'
}

@test "helm: install/upgrade/uninstall/rollback/test on a non-local context" {
  assert_ask 'helm upgrade --install oompa ./chart --kube-context wonka-factory'
  assert_ask 'helm uninstall oompa -n oompa --kube-context wonka-factory'
  assert_ask 'helm rollback oompa 3 --kube-context wonka-factory'
  assert_ask 'helm test oompa --kube-context wonka-factory'
}

@test "helm/kubectl: plugin wrappers still resolve to the real verb" {
  assert_ask 'helm secrets upgrade oompa ./chart --kube-context wonka-factory'
}

@test "wrappers and pipelines cannot smuggle a mutation" {
  assert_ask 'sh -c "helm upgrade oompa ./chart --kube-context wonka-factory"'
  assert_ask 'bash -lc "kubectl --context wonka-factory delete ns oompa"'
  assert_ask 'eval "kubectl --context wonka-factory delete pod squirrel-0"'
  assert_ask \
    'kubectl --context wonka-factory get pods -o name | xargs kubectl --context wonka-factory delete'
  assert_ask 'sudo kubectl --context wonka-factory delete pod squirrel-0'
  assert_ask 'make deploy && kubectl --context wonka-factory apply -f out.yaml'
}

@test "kubectl: chained context switch then mutate" {
  assert_ask 'kubectl config use-context wonka-factory && kubectl delete pod squirrel-0'
}

# =============================================================================
# command combinations — the wrapper must not change the verdict
#
# An agent composes commands: timeout, watch, xargs, loops, subshells, pipes,
# heredocs, backgrounding. Wrapping a read-only command must never start
# prompting, and wrapping a mutation must never stop prompting.
# =============================================================================

@test "combo: timeout keeps read-only read-only" {
  assert_pass 'timeout 30 kubectl --context wonka-factory get pods'
  assert_pass 'timeout 300 kubectl --context wonka-factory rollout status deploy/hamster-wheel'
  assert_pass 'timeout 300 helm template test chart --show-only x.yaml'
  assert_pass 'timeout 60 kubectl --context wonka-factory exec squirrel-0 -- cat /etc/x'
  assert_pass 'timeout -k 5 60 kubectl --context wonka-factory logs -f deploy/hamster-wheel'
}

@test "combo: timeout does not launder a mutation" {
  assert_ask 'timeout 300 kubectl --context wonka-factory delete pod squirrel-0'
  assert_ask 'timeout -k 5 600 helm upgrade --install oompa ./chart --kube-context wonka-factory'
  assert_ask 'timeout 1800 terraform apply -var-file=moonbase.tfvars'
  assert_ask 'timeout 600 argocd app sync sock-drawer'
  assert_ask 'timeout 120 openstack --os-cloud moonbase server delete hamster-01'
}

@test "combo: nice / ionice / nohup / stdbuf / background" {
  assert_pass 'nice -n 10 kubectl --context wonka-factory get pods -A'
  assert_pass 'stdbuf -oL kubectl --context wonka-factory logs -f deploy/hamster-wheel'
  assert_ask 'nice -n 10 kubectl --context wonka-factory delete pod squirrel-0'
  assert_ask 'nohup helm upgrade oompa ./chart --kube-context wonka-factory &'
  assert_ask 'ionice -c2 -n7 kubectl --context wonka-factory drain node-1'
}

@test "combo: watch re-running a command" {
  assert_pass 'watch -n 5 kubectl --context wonka-factory get pods'
  assert_pass 'watch -n 2 "kubectl --context wonka-factory rollout status deploy/web"'
  assert_ask 'watch -n 5 kubectl --context wonka-factory delete pod squirrel-0'
}

@test "combo: pipes feeding a mutation" {
  assert_ask 'helm template oompa ./chart | kubectl --context wonka-factory apply -f -'
  assert_ask 'cat manifests.yaml | kubectl --context wonka-factory apply -f -'
  assert_ask 'kustomize build overlays/moonbase | kubectl --context wonka-factory apply -f -'
  assert_ask 'kubectl --context wonka-factory get pods -o name | xargs -I{} kubectl --context wonka-factory delete {}'
  assert_ask 'helm template oompa ./chart | tee out.yaml | kubectl --context wonka-factory replace -f -'
}

@test "combo: pipes that stay read-only" {
  assert_pass 'helm template oompa ./chart | kubectl --context wonka-factory diff -f -'
  assert_pass 'helm template oompa ./chart | yq .spec | head -50'
  assert_pass 'kubectl --context wonka-factory get pods -o json | jq ".items[].metadata.name"'
  assert_pass 'kubectl --context wonka-factory logs deploy/hamster-wheel | grep -i "delete failed" | tail -20'
}

@test "combo: chained with && ; and ||" {
  assert_pass 'cd /repo && helm template test chart && echo done'
  assert_pass 'kubectl --context wonka-factory get ns; kubectl --context wonka-factory get pods -A'
  assert_ask 'kubectl --context wonka-factory get ns && kubectl --context wonka-factory delete ns sandbox'
  assert_ask 'helm lint ./chart || helm uninstall oompa --kube-context wonka-factory'
  assert_ask 'make build && kubectl --context wonka-factory apply -f out.yaml && echo ok'
}

@test "combo: loops and subshells" {
  assert_pass 'for ns in a b; do kubectl --context wonka-factory get pods -n $ns; done'
  assert_ask 'for ns in a b; do kubectl --context wonka-factory delete ns $ns; done'
  assert_ask 'while read -r p; do kubectl --context wonka-factory delete pod "$p"; done < pods.txt'
  assert_ask '(cd /repo && helm upgrade oompa ./chart --kube-context wonka-factory)'
}

@test "combo: command substitution and backticks" {
  assert_pass 'echo "pods: $(kubectl --context wonka-factory get pods -o name | wc -l)"'
  assert_ask 'kubectl --context wonka-factory delete pod $(kubectl --context wonka-factory get pods -o name)'
  assert_ask 'kubectl --context wonka-factory delete pod `kubectl --context wonka-factory get po -o name`'
}

@test "combo: heredocs and redirection" {
  assert_ask 'kubectl --context wonka-factory apply -f - <<EOF'
  assert_pass 'kubectl --context wonka-factory get cm -o yaml > /tmp/cm.yaml'
  assert_ask 'kubectl --context wonka-factory get cm -o yaml > /tmp/cm.yaml && kubectl --context wonka-factory replace -f /tmp/cm.yaml'
}

@test "combo: remote execution makes the local context meaningless" {
  assert_ask 'ssh hedgehog-bastion "kubectl --context orbstack delete pod squirrel-0"'
  assert_ask 'docker run --rm noodleshop/kubectl delete pod squirrel-0'
  assert_ask 'ansible-playbook deploy.yml -e "cmd=helm upgrade oompa ./chart"'
}

@test "combo: multi-line scripts" {
  assert_ask 'set -e
kubectl --context wonka-factory get ns
kubectl --context wonka-factory delete ns sandbox'
  assert_pass 'set -e
kubectl --context wonka-factory get ns
helm template test chart'
}

@test "combo: mixing tools in one command" {
  assert_ask 'terraform output -json > tf.json && kubectl --context wonka-factory apply -f manifests/'
  assert_ask 'kubectl --context wonka-factory get ns && terraform apply -var-file=moonbase.tfvars'
  assert_ask 'kubectl --context wonka-factory get pods && argocd app sync oompa'
  assert_pass 'argocd app diff oompa && kubectl --context wonka-factory get pods'
}

# =============================================================================
# terraform / tofu
# =============================================================================

@test "terraform: read-only commands pass" {
  assert_pass 'terraform plan -var-file=moonbase.tfvars'
  assert_pass 'terraform plan -destroy -var-file=moonbase.tfvars'
  assert_pass 'terraform show plan.out'
  assert_pass 'terraform show -json apply.tfplan'
  assert_pass 'terraform output -json'
  assert_pass 'terraform validate'
  assert_pass 'terraform fmt -recursive'
  assert_pass 'terraform state list'
  assert_pass 'terraform state show aws_instance.disco_ball'
  assert_pass 'terraform -chdir=envs/moonbase providers'
  assert_pass 'terraform workspace list'
  assert_pass 'terraform workspace select moonbase'
  assert_pass 'terraform init'
}

@test "terraform: plan writing a plan file called apply" {
  assert_pass 'terraform plan -out apply.tfplan'
}

@test "terraform: state-mutating commands ask" {
  assert_ask 'terraform apply -var-file=moonbase.tfvars'
  assert_ask 'terraform apply plan.out'
  assert_ask 'terraform -chdir=envs/moonbase destroy'
  assert_ask 'terraform import aws_instance.disco_ball i-1234'
  assert_ask 'terraform state rm aws_instance.disco_ball'
  assert_ask 'terraform state mv aws_instance.tuba aws_instance.b'
  assert_ask 'terraform workspace delete rusty-sandcastle'
  assert_ask 'terraform force-unlock 1234-5678'
  assert_ask 'tofu apply -auto-approve'
  assert_ask 'TF_WORKSPACE=moonbase terraform apply'
  assert_ask 'terraform init -migrate-state'
  assert_ask 'sh -c "terraform apply -auto-approve"'
}

@test "terraform: mentions are not invocations" {
  assert_pass 'echo "next step: terraform apply"'
  assert_pass 'grep -rn "terraform destroy" ./docs'
}

# =============================================================================
# openstack
# =============================================================================

@test "openstack: read-only commands pass" {
  assert_pass 'openstack --os-cloud moonbase server list'
  assert_pass 'openstack --os-cloud moonbase server show hamster-01'
  assert_pass 'openstack --os-cloud moonbase volume list --long'
  assert_pass 'openstack --os-cloud moonbase image list -f json'
}

@test "openstack: a verb-shaped flag value does not trip the guard" {
  assert_pass 'openstack --os-cloud moonbase server list --name create-runner'
  assert_pass 'openstack --os-cloud moonbase server show delete-me-later'
  assert_pass 'openstack --os-cloud moonbase server list -f value | grep delete'
}

@test "openstack: mutations ask" {
  assert_ask 'openstack --os-cloud moonbase server delete hamster-01'
  assert_ask 'openstack --os-cloud moonbase volume create --size 10 pickle-jar'
  assert_ask 'openstack --os-cloud moonbase server reboot --hard hamster-01'
  assert_ask 'openstack --os-cloud sandcastle server set --name hamster-02 hamster-01'
  assert_ask 'OS_CLOUD=moonbase openstack server stop hamster-01'
  assert_ask 'sh -c "openstack --os-cloud moonbase server delete hamster-01"'
}

@test "openstack: the prompt names the cloud the mutation lands in" {
  # Every mutation asks whichever cloud it hits, so the risk here is the prompt
  # naming the read's cloud and getting the delete approved as if it were that.
  local cmd='openstack --os-cloud sandcastle server list && openstack --os-cloud moonbase server delete hamster-01'
  assert_ask "$cmd"
  assert_reason "$cmd" 'moonbase'
}

# =============================================================================
# argocd
# =============================================================================

@test "argocd: read-only commands pass" {
  assert_pass 'argocd app get sock-drawer --server argocd.example.com'
  assert_pass 'argocd app list -o name'
  assert_pass 'argocd app diff sock-drawer'
  assert_pass 'argocd app manifests sock-drawer'
  assert_pass 'argocd app history sock-drawer'
  assert_pass 'argocd app logs sock-drawer --tail 50'
  assert_pass 'argocd app sync sock-drawer --dry-run'
  assert_pass 'argocd version --client'
}

@test "argocd: an app name containing a verb does not trip the guard" {
  assert_pass 'argocd app get sock-drawer-set'
  assert_pass 'argocd app get oompa --revision sync-test'
}

@test "argocd: mutations ask" {
  assert_ask 'argocd app sync sock-drawer'
  assert_ask 'argocd app sync sock-drawer --prune --force'
  assert_ask 'argocd app delete sock-drawer --cascade'
  assert_ask 'argocd app rollback sock-drawer 3'
  assert_ask 'argocd app set sock-drawer -p image.tag=1.2.3'
  assert_ask 'argocd app patch-resource sock-drawer --kind Deployment'
  assert_ask 'argocd proj create pancake-team'
  assert_ask 'argocd cluster add waffle-iron'
  assert_ask 'sh -c "argocd app sync sock-drawer"'
}

@test "argocd: a dry run covers its own invocation only" {
  assert_ask 'argocd app sync sock-drawer --dry-run && argocd app sync sock-drawer'
}

@test "argocd: the prompt names the server the sync lands on" {
  local cmd='argocd --server staging.example.com app get sock-drawer && argocd --server prod.example.com app sync sock-drawer'
  assert_ask "$cmd"
  assert_reason "$cmd" 'prod.example.com'
}

# =============================================================================
# cross-cutting: hooks must be inert for unrelated commands
# =============================================================================

@test "unrelated commands never produce output" {
  assert_pass 'git status --short'
  assert_pass 'npm test'
  assert_pass 'rg -n "apply" src/'
  assert_pass 'docker compose up -d'
  assert_pass 'ls -la && pwd'
}

@test "malformed or empty hook input is ignored" {
  run --separate-stderr "$HOOK" <<<'{}'
  [ -z "$output" ]
  run --separate-stderr "$HOOK" <<<'not json'
  [ -z "$output" ]
}

# =============================================================================
# writing a command is not running it; running it from a file is
# =============================================================================

@test "heredoc: a runbook documenting a mutation does not prompt" {
  assert_pass "$(printf 'cat > runbook.md <<EOF\nkubectl --context wonka-factory delete pod hamster-runner-1\ngit push --force origin main\nEOF')"
  assert_pass "$(printf "cat > runbook.md <<'DOC'\nopenstack server delete pancake-1\nDOC")"
  assert_pass "$(printf 'cat > runbook.md <<-"DOC"\n\targocd app sync pancake-service\n\tDOC')"
}

@test "heredoc: the line that opens it is still a real command" {
  assert_ask "$(printf 'kubectl --context wonka-factory apply -f - <<EOF\nkind: Pod\nEOF')"
  assert_reason "$(printf 'kubectl --context wonka-factory apply -f - <<EOF\nkind: Pod\nEOF')" 'wonka-factory'
}

@test "heredoc: a mutation after the terminator is still classified" {
  assert_ask "$(printf 'cat > runbook.md <<EOF\njust docs\nEOF\nkubectl --context wonka-factory delete pod hamster-runner-1')"
}

@test "herestrings and shift operators are not heredocs" {
  assert_pass 'grep pancake <<< "kubectl delete pod hamster-runner-1"'
  assert_pass 'echo $((1<<3))'
}

@test "scripts: executing one carries its contents into the guard" {
  printf 'kubectl --context wonka-factory delete pod hamster-runner-1\n' > "$BATS_TEST_TMPDIR/deploy.sh"
  chmod +x "$BATS_TEST_TMPDIR/deploy.sh"
  assert_ask "bash $BATS_TEST_TMPDIR/deploy.sh"
  assert_ask "$BATS_TEST_TMPDIR/deploy.sh"
  assert_ask "source $BATS_TEST_TMPDIR/deploy.sh"
  assert_reason "bash $BATS_TEST_TMPDIR/deploy.sh" 'wonka-factory'
}

@test "scripts: contents that are only data do not prompt" {
  printf '# kubectl --context wonka-factory delete pod hamster-runner-1\necho "kubectl --context wonka-factory delete pod hamster-runner-1"\n' \
    > "$BATS_TEST_TMPDIR/safe.sh"
  assert_pass "bash $BATS_TEST_TMPDIR/safe.sh"

  printf 'cat > r.md <<EOF\nkubectl --context wonka-factory delete pod hamster-runner-1\nEOF\n' \
    > "$BATS_TEST_TMPDIR/doc.sh"
  assert_pass "bash $BATS_TEST_TMPDIR/doc.sh"

  assert_pass "bash $BATS_TEST_TMPDIR/does-not-exist.sh"
}

# =============================================================================
# git — only pushes that destroy a protected branch
# =============================================================================

@test "git: ordinary pushes pass" {
  assert_pass 'git push'
  assert_pass 'git push origin main'
  assert_pass 'git push -u origin feature/pancake-stack'
  assert_pass 'git push --delete origin feature/pancake-stack'
  assert_pass 'git commit -m "push --force to main"'
}

@test "git: force-pushing your own topic branch passes" {
  assert_pass 'git push --force origin feature/pancake-stack'
  assert_pass 'git push --force-with-lease origin feature/pancake-stack'
  assert_pass 'git push --force origin feature/main-nav'
}

@test "git: destroying a protected branch asks" {
  assert_ask 'git push --force origin main'
  assert_ask 'git push --force-with-lease origin main'
  assert_ask 'git push -f origin master'
  assert_ask 'git push origin +main'
  assert_ask 'git push origin :main'
  assert_ask 'git push --delete origin main'
  assert_ask 'git push origin HEAD:main --force'
  assert_ask 'git push --mirror backup'
}

@test "git: the prompt names the remote the push lands on" {
  assert_reason 'git push --mirror backup' 'backup'
  assert_reason 'git push --force origin develop' 'develop'
}

# =============================================================================
# gh / glab — collaboration passes, publishing and destruction ask
# =============================================================================

@test "gh: routine collaboration passes" {
  assert_pass 'gh pr create --title "add pancake stack" --body x'
  assert_pass 'gh pr comment 12 --body "looks good"'
  assert_pass 'gh pr review 12 --approve'
  assert_pass 'gh pr edit 12 --add-label pancake'
  assert_pass 'gh issue create --title "hamster wheel squeaks"'
  assert_pass 'gh pr list'
  assert_pass 'gh pr checkout feature/delete-old-code'
  assert_pass 'gh run list'
  assert_pass 'gh config set editor vim'
}

@test "gh: publishing and destruction ask" {
  assert_ask 'gh pr merge 12 --squash'
  assert_ask 'gh repo delete noodleshop/scratch'
  assert_ask 'gh release create v1.0.0'
  assert_ask 'gh secret set WONKA_TOKEN --body x'
  assert_ask 'gh workflow run deploy.yml'
  assert_ask 'gh api repos/noodleshop/pancake/issues -X DELETE'
}

@test "gh: the prompt names the repo the command targets, not the checkout" {
  assert_reason 'gh repo delete noodleshop/scratch' 'noodleshop/scratch'
  assert_reason 'gh api repos/noodleshop/pancake/issues -X DELETE' 'noodleshop/pancake'
  assert_reason 'gh pr merge 12 -R noodleshop/pancake' 'noodleshop/pancake'
}

@test "glab: routine collaboration passes, destruction asks" {
  assert_pass 'glab mr create --title "add pancake stack"'
  assert_pass 'glab mr note 3 -m "looks good"'
  assert_pass 'glab mr list'
  assert_pass 'glab ci lint'
  assert_ask 'glab mr merge 3'
  assert_ask 'glab repo delete noodleshop/scratch'
  assert_reason 'glab repo delete noodleshop/scratch' 'noodleshop/scratch'
}
