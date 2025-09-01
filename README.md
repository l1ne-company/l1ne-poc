# l1ne-poc

 > “This project is a proof of concept provided for educational and demonstration purposes only. The production-ready implementation and related intellectual property will remain proprietary.”

          Control Plane (Your Orchestrator)
        +-----------------------------------------+
        |  Firewall / Front Service               |
        |   - Receives API requests (user / CLI)  |
        |   - Load balances requests              |
        |   - Enforces security/firewall rules    |
        |                                         |
        |  Orchestrator Core                      |
        |   - Desired state vs. actual state      |
        |   - Scheduling: picks target node       |
        |   - Talks to systemd via D-Bus (remote) |
        |   - Applies infra changes via Terraform |
        |                                         |
        |  State Backend                          |
        |   - Stores service definitions, scale   |
        |   - Could be DB / Terraform state       |
        +-----------------------------------------+
                       |
                       v
    +--------------------+     +--------------------+     +--------------------+
    |   NixOS Node 1     |     |   NixOS Node 2     |     |   NixOS Node 3     |
    | systemd (PID 1)    |     | systemd (PID 1)    |     | systemd (PID 1)    |
    |  - myapp@1.service |     |  - myapp@2.service |     |  - myapp@3.service |
    |  - resource cgroups|     |  - resource cgroups|     |  - resource cgroups|
    |  - journald logs   |     |  - journald logs   |     |  - journald logs   |
    |  - networking/firew|     |  - networking/firew|     |  - networking/firew|
    +--------------------+     +--------------------+     +--------------------+
