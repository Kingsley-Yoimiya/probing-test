# Ascend 镜像 / 灌装

用户提供设备代码与底包后在此补：

- `Dockerfile` 或 `env.defaults` 片段  
- `install_env_to_pods.sh`（Probing / stress-ng / shm）  

在推送权限与镜像名未定时，优先 **现网 pod 灌装**（对标 MetaX `install_env_to_pods.sh`）。
