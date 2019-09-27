#!/bin/sh
# Readiness probe script for the mysql-proxy role

set -o errexit errunset

# Make kubectl available
PATH="/var/vcap/packages/kubectl/bin:${PATH}"
export PATH

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
SERVICE="<%= p('gp.switchboard.service') %>"
RENEWAL="<%= p('gp.switchboard.renewal') %>"
ANNOTATION=skiff-leader
LOG_DIR=/var/vcap/sys/log/switchboard-leader
LOG="${LOG_DIR}/switchboard-leader.log"

# Clear log. We do not accumulate over time, and it will always show
# only the results from the last call to this script.
mkdir -p "${LOG_DIR}"
rm -f "${LOG}"

log () { echo "$@" >> "${LOG}" ; }

now () {
    # timestamp, seconds of the epoch.
    date '+%s'
}

get_claim () {
    log retrieval "${NAMESPACE}:${SERVICE}" :: "${ANNOTATION}"
    # CLAIM is exported for use in `our_claim` and `is_expired`
    export CLAIM="$(kubectl get service \
			   --namespace "${NAMESPACE}" "${SERVICE}" \
			   --output "jsonpath={.metadata.annotations."${ANNOTATION}"}")"
    # CLAIM='claimant:claimtime' -- claimtime unit is [epoch].
    log claim: "${CLAIM}"
    test -n "${CLAIM}"
}

our_claim () {
    local CLAIMANT="${CLAIM%%:*}"
    log self? ${HOSTNAME} :: ${CLAIMANT}
    test "${CLAIMANT}" == "${HOSTNAME}"
}

is_expired () {
    local CLAIMSEC="${CLAIM#*:}"
    NOW="$(now)"
    log expired? $NOW :: $CLAIMSEC
    test "$(( ${CLAIMSEC} + {RENEWAL} ))" -lt "${NOW}"
}

make_claim () {
    local NEWCLAIM="${HOSTNAME}:$(now)"
    log make first claim $NEWCLAIM
    kubectl annotate service \
	    --namespace "${NAMESPACE}" "${SERVICE}" "${ANNOTATION}=${NEWCLAIM}" \
	    >> "${LOG}" 2>&1
}

extend_claim () {
    local NEWCLAIM=${HOSTNAME}:$(now)
    log extend claim $NEWCLAIM
    kubectl annotate --overwrite service \
	    --namespace "${NAMESPACE}" "${SERVICE}" "${ANNOTATION}=${NEWCLAIM}" \
	    >> "${LOG}" 2>&1
}

clear_claims() {
    log clear expired claim
    kubectl annotate service \
	    --namespace "${NAMESPACE}" "${SERVICE}" "${ANNOTATION}-" \
	    >> "${LOG}" 2>&1
}

claim () {
    if ! get_claim ; then
	log no claims
	make_claim || return 1
	return 0
    fi
    log verify claim
    if our_claim ; then
	# (x) Extending the claim strongly relies on a D a good deal
	# longer than the healthcheck interval. This gives the current
	# claimant a high chance of extending its claim without
	# contest from other pods as they see it as 'not expired'.
	# That said given that here uses --overwrite we may very well
	# run over such a contesting attempt.
	extend_claim && return 0
    fi
    if is_expired ; then
	clear_claims
	# note, somebody else can claim it here before we manage to.
	# note 2: while --overwrite would allow us to contest that it
	# becomes a hassle to then detect who has ultimately won.
	make_claim || return 1
	# the previous claimer's extend_claim may run us over here as
	# it uses --overwrite if timing lines up that:
	# - it verified its claim,
	# - we deleted and wrote our claim and
	# - it then overwrites it with its extension.
	# For that to happen the previous claimer's check has to be
	# delayed by pretty exactly (D - check interval) seconds.
	# See (x). So, perform a second check to see if our claim stuck.
	sleep 1
	get_claim && our_claim || return 1
	return 0
    fi
    log standby
    return 1
}

present() {
    head -c0 </dev/tcp/${HOSTNAME}/1936
}

# -------------------------------------------------------------

if present ; then
    log listener present
    if claim ; then
	log OK
	exit 0
    fi
else
    log listener dead
    if get_claim && our_claim ; then
	clear_claims
    fi
fi
log DEFER
exit 1
