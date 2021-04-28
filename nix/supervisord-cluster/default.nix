let
  basePortDefault    = 30000;
  cacheDirDefault    = "${__getEnv "HOME"}/.cache";
  stateDirDefault    = "state-cluster";
  profileNameDefault = "default-mary";
in
{ pkgs
, lib
, bech32
, basePort              ? basePortDefault
, stateDir              ? stateDirDefault
, cacheDir              ? cacheDirDefault
, extraSupervisorConfig ? {}
, useCabalRun           ? false
, workbenchDevMode      ? false
, enableEKG             ? true
##
, profileName           ? profileNameDefault
, batchName             ? "plain"
, ...
}:
with lib;
let
  backend =
    rec
    { ## Generic Nix bits:
      topologyForNode =
        { profile, nodeSpec }:
        let inherit (nodeSpec) name i; in
        pkgs.runWorkbench "topology-${name}.json"
          (if nodeSpec.isProducer
           then "topology for-local-node     ${toString i}   ${profile.topology.files} ${toString basePort}"
           else "topology for-local-observer ${profile.name} ${profile.topology.files} ${toString basePort}");

      finaliseNodeService =
        { name, i, isProducer, ... }: svc: recursiveUpdate svc
          ({
            stateDir       = stateDir + "/${name}";
            ## Everything is local in the supervisord setup:
            socketPath     = "node.socket";
            topology       = "topology.json";
            nodeConfigFile = "config.json";
          } // optionalAttrs useCabalRun {
            executable     = "cabal run exe:cardano-node --";
          } // optionalAttrs isProducer {
            operationalCertificate = "../genesis/node-keys/node${toString i}.opcert";
            kesKey         = "../genesis/node-keys/node-kes${toString i}.skey";
            vrfKey         = "../genesis/node-keys/node-vrf${toString i}.skey";
          });

      finaliseNodeConfig =
        { port, ... }: cfg: recursiveUpdate cfg
          ({
            ShelleyGenesisFile   = "../genesis/genesis.json";
            ByronGenesisFile     = "../genesis/byron/genesis.json";
          } // optionalAttrs enableEKG {
            hasEKG               = port + supervisord.portShiftEkg;
            hasPrometheus        = [ "127.0.0.1" (port + supervisord.portShiftPrometheus) ];
            setupBackends = [
              "EKGViewBK"
            ];
          });

      ## Backend-specific Nix bits:
      supervisord =
        {
          inherit
            extraSupervisorConfig;

          portShiftEkg        = 100;
          portShiftPrometheus = 200;

          mkSupervisorConf =
            profile:
            pkgs.callPackage ./supervisor-conf.nix
            { inherit (profile) node-services;
              inherit
                pkgs lib stateDir
                basePort
                extraSupervisorConfig;
            };
        };
    };

  environment =
    {
      cardanoLib = pkgs.commonLib.cardanoLib;
      inherit
        stateDir cacheDir
        basePort;
    };

  workbenchProfiles = pkgs.workbench.generateProfiles
    { inherit pkgs backend environment; };
in

let
  profile = workbenchProfiles.profiles."${profileName}"
    or (throw "No such profile: ${profileName};  Known profiles: ${toString (__attrNames workbenchProfiles.profiles)}");

  inherit (profile.value) era composition monetary;

  path = makeBinPath path';
  path' =
    [ bech32 pkgs.jq pkgs.gnused pkgs.coreutils pkgs.bash pkgs.moreutils
    ]
    ## In dev mode, call the script directly:
    ++ optionals (!workbenchDevMode)
    [ pkgs.workbench.workbench ];

  start = pkgs.writeScriptBin "start-cluster" ''
    set -euo pipefail

    export PATH=$PATH:${path}
    export WORKBENCH_BACKEND=${../workbench}/supervisor.sh

    wb backend assert-is supervisor

    wb backend assert-stopped

    batch_name=${batchName}

    while test $# -gt 0
    do case "$1" in
        --batch-name ) batch_name=$2; shift;;
        --trace | --debug ) set -x;;
        --trace-wb | --trace-workbench ) export WORKBENCH_EXTRA_FLAGS=--trace;;
        * ) break;; esac; shift; done

    workbench-prebuild-executables

    if test -e "${stateDir}" -a ! -L "${stateDir}"
    then echo "workbench ERROR:  state directory exists, but is not a symlink -- please remove it or choose another:  ${stateDir}"; exit 1; fi

    allocate_args=(
        --cachedir      "${cacheDir}"
        --base-port      ${basePort}
        --stagger-ports
        --port-shift-ekg        100
        --port-shift-prometheus 200
      )
    wb run allocate $batch_name ${profile.name} "''${allocate_args[@]}"

    ln -sf "$(wb run current-path)" "${stateDir}"
    mkdir -p                        "${stateDir}"/supervisor

    ${__concatStringsSep "\n"
      (flip mapAttrsToList profile.node-services
        (name: svc:
          ''
          cp ${svc.serviceConfig.JSON} ${stateDir}/${name}/service-config.json
          cp ${svc.nodeConfig.JSON}    ${stateDir}/${name}/config.json
          cp ${svc.topology.JSON}      ${stateDir}/${name}/topology.json
          cp ${svc.startupScript}      ${stateDir}/${name}/start.sh
          ''
        ))}

    SUPERVISOR_CONF=${supervisord.mkSupervisorConf profile}
    cp $SUPERVISOR_CONF ${stateDir}/supervisor/supervisord.conf
    ${pkgs.python3Packages.supervisor}/bin/supervisord \
        --config $SUPERVISOR_CONF $@
    if test ! -v CARDANO_NODE_SOCKET_PATH
    then export  CARDANO_NODE_SOCKET_PATH=$(wb local get-node-socket-path ${stateDir})
    fi

    wb run start $(wb run current-name)

    wb backend wait-for-local-node-socket
    wb supervisor record-node-pids     "${stateDir}"

    echo 'workbench:  cluster started. Run `stop-cluster` to stop'
  '';
  stop = pkgs.writeScriptBin "stop-cluster" ''
    set -euo pipefail

    while test $# -gt 0
    do case "$1" in
        --trace | --debug ) set -x;;
        * ) break;; esac; shift; done

    ${pkgs.python3Packages.supervisor}/bin/supervisorctl stop all
    if wb local supervisord-running
    then
      if test -f "${stateDir}/supervisor/cardano-node.pids"
      then kill $(<${stateDir}/supervisor/supervisord.pid) $(<${stateDir}/supervisor/cardano-node.pids)
      else pkill supervisord
      fi
      echo "workbench:  cluster terminated"
      rm -f ${stateDir}/supervisor/supervisord.pid ${stateDir}/supervisor/cardano-node.pids
    else
      echo "workbench:  cluster is not running"
    fi
  '';

in
{
  inherit (pkgs) workbench;
  inherit (workbenchProfiles) profilesJSON;
  inherit profile stateDir start stop;
}
