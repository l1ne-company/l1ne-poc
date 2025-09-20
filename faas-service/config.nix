# Simple config for L1NE - just the essentials
{ pkgs, ... }:
{
  # Web server definition
  service = {
    # Name from CLI: --service=axum-api
    name = "axum-api";
    
    # Command to run
    command = "./axum-server";
    
    # Environment variables
    environment = {
      RUST_LOG = "info";
    };
    
    # Ports from CLI: --nodes=8080,8081,8082
    # L1NE handles load balancing between these
    ports = [ 8080 8081 8082 ];
    
    # Resource limits from CLI: --mem-percent=50 --cpu-percent=50
    resources = {
      memoryPercent = 50;
      cpuPercent = 50;
    };
  };
}