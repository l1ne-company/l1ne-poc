{
  description = ''
    A L1NE FAAS module for deploying services to NixOS nodes.
    
    Deploy containerized or native services with resource limits and automatic orchestration.
    
    [Documentation](https://l1ne.io/docs/modules/faas) - [Source](https://github.com/l1ne-company/faas-module).
  '';
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  
  outputs = { self, nixpkgs }: {
    l1neModules.default = 
      { pkgs, lib, config, ... }:
      let
        # Service instance submodule (like k8s pod)
        instanceSubmodule.options = {
          port = lib.mkOption {
            type = lib.types.port;
            description = "Port this service instance listens on (like k8s container port)";
            example = 8080;
          };
          
          memPercent = lib.mkOption {
            type = lib.types.ints.between 1 100;
            description = "Memory limit as percentage of FAAS pool";
            default = 50;
          };
          
          cpuPercent = lib.mkOption {
            type = lib.types.ints.between 1 100;
            description = "CPU limit as percentage of FAAS pool";
            default = 50;
          };
          
          replicas = lib.mkOption {
            type = lib.types.ints.between 1 4;
            description = "Number of instances (like k8s replicas)";
            default = 1;
          };
        };
        
        # Main FAAS service submodule
        faasServiceSubmodule.options = {
          name = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Service name (provided via CLI --service flag)";
            example = "backend-api";
          } // {
            name = "service name";
          };
          
          command = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Command to run the service";
            example = "node server.js";
          } // {
            name = "service command";
          };
          
          workingDirectory = lib.mkOption {
            type = lib.types.path;
            description = "Working directory for the service";
            default = "/var/lib/faas";
          };
          
          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            description = "Environment variables for the service";
            default = {};
            example = {
              NODE_ENV = "production";
              DATABASE_URL = "postgresql://localhost:5432/db";
            };
          };
          
          instances = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule instanceSubmodule);
            description = "Service instances configuration (ports and resources)";
            default = [{
              port = 8080;
              memPercent = 50;
              cpuPercent = 50;
              replicas = 1;
            }];
          };
          
          healthCheck = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                endpoint = lib.mkOption {
                  type = lib.types.str;
                  default = "/health";
                  description = "Health check endpoint";
                };
                interval = lib.mkOption {
                  type = lib.types.int;
                  default = 30;
                  description = "Health check interval in seconds";
                };
                timeout = lib.mkOption {
                  type = lib.types.int;
                  default = 5;
                  description = "Health check timeout in seconds";
                };
              };
            });
            default = null;
            description = "Health check configuration";
          };
          
          dependencies = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            description = "Runtime dependencies required by the service";
            default = [];
          };
          
          wal = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Enable centralized WAL logging";
                };
                path = lib.mkOption {
                  type = lib.types.path;
                  default = "/var/log/l1ne/wal";
                  description = "Path to WAL storage";
                };
              };
            };
            default = {};
            description = "Write-Ahead Log configuration for centralized logging";
          };
        };
        
        # L1NE orchestrator configuration
        orchestratorConfig = {
          port = 42069;
          stateDir = "/var/lib/l1ne";
          maxNodes = 4; # POC limit
          faasPool = {
            totalMemory = "4GiB";
            totalCpu = 400; # 4 cores = 400%
          };
        };
        
      in {
        options = {
          faas = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule faasServiceSubmodule);
            description = "FAAS services managed by L1NE orchestrator";
            default = {};
          };
          
          l1ne = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable L1NE orchestrator";
            };
            
            development = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable development mode";
            };
          };
        };
        
        config = lib.mkIf config.l1ne.enable {
          # L1NE Orchestrator systemd service
          systemd.services.l1ne-orchestrator = {
            description = "L1NE Service Orchestrator";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            
            serviceConfig = {
              Type = "simple";
              DynamicUser = true;
              StateDirectory = "l1ne";
              LogsDirectory = "l1ne";
              ExecStart = "${pkgs.l1ne or self.packages.${pkgs.system}.l1ne}/bin/l1ne start " +
                "--nodes=${lib.concatMapStringsSep "," (inst: toString inst.port) 
                  (lib.flatten (lib.mapAttrsToList (name: svc: svc.instances) config.faas))} " +
                "--service=orchestrator " +
                "--bind=127.0.0.1:${toString orchestratorConfig.port} " +
                "${orchestratorConfig.stateDir}/config.nix ${orchestratorConfig.stateDir}";
              Restart = "on-failure";
              RestartSec = 10;
            };
            
            environment = {
              L1NE_ORCHESTRATOR_PORT = toString orchestratorConfig.port;
              L1NE_STATE_DIR = orchestratorConfig.stateDir;
            };
          };
          
          # Generate systemd services for each FAAS service instance
          systemd.services = lib.mkMerge (
            lib.flatten (
              lib.mapAttrsToList (serviceName: serviceConfig:
                lib.imap0 (idx: instance:
                  let
                    instanceName = "${serviceName}-${toString idx}";
                    memoryLimit = "${toString (instance.memPercent * 40)}M"; # 40M per 1% of 4GiB
                    cpuQuota = "${toString instance.cpuPercent}%";
                  in {
                    "faas-${instanceName}" = {
                      description = "FAAS Service: ${serviceName} (Instance ${toString idx})";
                      wantedBy = [ "multi-user.target" ];
                      after = [ "l1ne-orchestrator.service" ];
                      requires = [ "l1ne-orchestrator.service" ];
                      
                      environment = serviceConfig.environment // {
                        PORT = toString instance.port;
                        L1NE_SERVICE_NAME = serviceName;
                        L1NE_INSTANCE_ID = toString idx;
                      };
                      
                      serviceConfig = {
                        Type = "simple";
                        DynamicUser = true;
                        WorkingDirectory = serviceConfig.workingDirectory;
                        StateDirectory = "faas/${serviceName}";
                        
                        # Resource limits
                        MemoryMax = memoryLimit;
                        CPUQuota = cpuQuota;
                        
                        # Security
                        PrivateTmp = true;
                        ProtectSystem = "strict";
                        ProtectHome = true;
                        NoNewPrivileges = true;
                        
                        ExecStart = lib.getExe (
                          pkgs.writeShellApplication {
                            name = "start-${instanceName}";
                            runtimeInputs = serviceConfig.dependencies;
                            text = ''
                              # Setup WAL logging if enabled
                              ${lib.optionalString serviceConfig.wal.enable ''
                                exec > >(tee -a ${serviceConfig.wal.path}/${serviceName}-${toString idx}.log)
                                exec 2>&1
                              ''}
                              
                              # Start the service
                              ${serviceConfig.command}
                            '';
                          }
                        );
                        
                        Restart = "always";
                        RestartSec = 5;
                      };
                      
                      # Health check timer if configured
                      ${lib.optionalString (serviceConfig.healthCheck != null) ''
                        unitConfig.StartLimitInterval = serviceConfig.healthCheck.interval * 2;
                        unitConfig.StartLimitBurst = 3;
                      ''}
                    };
                  }
                ) serviceConfig.instances
              ) config.faas
            )
          );
          
          # Configure nginx reverse proxy for services
          services.nginx = {
            enable = true;
            virtualHosts.faas = {
              listen = [{
                addr = "127.0.0.1";
                port = 80;
              }];
              
              locations = lib.mkMerge (
                lib.flatten (
                  lib.mapAttrsToList (serviceName: serviceConfig:
                    map (instance: {
                      "/${serviceName}".proxyPass = "http://127.0.0.1:${toString instance.port}";
                    }) serviceConfig.instances
                  ) config.faas
                )
              );
            };
          };
          
          # WAL directory setup
          systemd.tmpfiles.rules = lib.flatten (
            lib.mapAttrsToList (serviceName: serviceConfig:
              lib.optional serviceConfig.wal.enable
                "d ${serviceConfig.wal.path} 0755 root root -"
            ) config.faas
          );
          
          # Firewall rules
          networking.firewall = {
            allowedTCPPorts = [ orchestratorConfig.port ] ++
              lib.flatten (lib.mapAttrsToList (name: svc: 
                map (inst: inst.port) svc.instances
              ) config.faas);
          };
        };
      };
  };
}