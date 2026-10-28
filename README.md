
## Mock Environment

- https://github.com/Amitmund/technical-challenge/tree/main/home_lab

- Initial README.md have the overal implementation.
- Using `nnn_deploy*` and `nnn_verify*` as sequence for setting of ubuntu home lab environment.


## How to build and test the lab:

**STEPS**:

- Please create an ubuntu system. ( I am using ubuntu 24.04 )
- git clone https://github.com/Amitmund/technical-challenge.git
- You can also go through the README.md within the home_lab for all the steps.
- But I have created related scripts that you can execute.
- The naming convention should explain what its doing.
- The scripts will also have note, logic, execution commands, expected output and current output, along with further verify scripts.

```
cd technical-challenge/home_lab

And bash <script_name>

001_deploy_ubuntu_lab_host_setup.sh
001_verify_ubuntu_lab_host_setup.sh
002_deploy_networks_and_isolation.sh
002_verify_networks_and_isolation.sh
003_deploy_saas_redis.sh
003_verify_saas_redis.sh
004_deploy_kind_k8s.sh
004_verify_kind_k8s.sh
005_deploy_gateway_and_baremetal.sh
005_verify_gateway_and_baremetal.sh
006_verify_negative_isolation.sh
007_deploy_wireguard_gateway.sh
007_verify_wireguard_gateway.sh
008_deploy_wireguard_baremetal.sh
008_verify_wireguard_baremetal.sh
verify_all_network_interfaces.sh
```

---

My further finding and learning:

- lession_learning.md
- README.md ( For the complete note)
- network_research_mode.md

---

