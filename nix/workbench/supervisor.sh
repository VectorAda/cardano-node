usage_supervisor() {
     usage "supervisor" "Manage a local cluster" <<EOF
    is-running       Test if 'supervisord' is running

    get-node-socket-path STATE-DIR
                     Given a state dir, print the default node socket path
                       for 'cardano-cli'

    wait-for-local-node-socket
                     Given a state dir, wait until a node socket appears

    record-node-pids STATE-DIR
                     Given a state dir, record node pids
EOF
}

supervisor() {
local op=${1:-$(usage_supervisor)}; shift

case "${op}" in
    name  )
        echo 'supervisor';;

    is-running )
        test "$(sleep 0.5s; netstat -pltn 2>/dev/null | grep ':9001 ' | wc -l)" != "0"
        ;;

    get-node-socket-path )
        local usage="USAGE: wb supervisor $op STATE-DIR"
        local state_dir=${1:?$usage}

        echo -n $state_dir/node-0/node.socket
        ;;

    wait-for-local-node-socket )
        while test ! -S $CARDANO_NODE_SOCKET_PATH
        do msg "waiting 5 seconds for $CARDANO_NODE_SOCKET_PATH to appear.."
           sleep 5
        done
        ;;

    record-extended-env-config )
        local usage="USAGE: wb supervisor $op ENV-JSON [ENV-CONFIG-OPTS..]"
        local env_json=${1:?$usage}

        while test $# -gt 0
        do case "$1" in
               --port-shift-ekg )        port_shift_ekg=$2; shift;;
               --port-shift-prometheus ) port_shift_prometheus=$2; shift;;
               --* ) msg "FATAL:  unknown flag '$1'"; usage_supervisor;;
               * ) break;; esac; shift; done

        local env_json="$env_json"
        local args=(
            --argjson port_shift_ekg        "$port_shift_ekg"
            --argjson port_shift_prometheus "$port_shift_prometheus"
        )
        jq_fmutate "$env_json" '. *
          { port_shift_ekg:        $port_shift_ekg
          , port_shift_prometheus: $port_shift_prometheus
          }
        ' "${args[@]}"
        ;;

    describe-run )
        local usage="USAGE: wb supervisor $op RUN-DIR"
        local dir=${1:?$usage}

        local base_port=$(jq .base_port "$dir"/env.json)
        local port_ekg=$((       base_port+$(jq .port_shift_ekg        "$dir"/env.json)))
        local port_prometheus=$((base_port+$(jq .port_shift_prometheus "$dir"/env.json)))

        cat <<EOF
  - EKG URL (node-0):        http://localhost:$port_ekg/
  - Prometheus URL (node-0): http://localhost:$port_prometheus/metrics
EOF
        ;;

    record-node-pids )
        local usage="USAGE: wb supervisor $op RUN-DIR"
        local dir=${1:?$usage}

        msg 'recording node pids..'
        pstree -Ap "$(cat "$dir"/supervisor/supervisord.pid)" |
            grep 'cabal.*cardano-node' |
            sed -e 's/^.*-+-cardano-node(\([0-9]*\))-.*$/\1/' \
                > "$dir"/supervisor/cardano-node.pids
        ;;

    * ) usage_supervisor;; esac
}
