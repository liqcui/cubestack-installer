# 版本套装档案: kubespray v2.32.1(本文件由 cubestack-version-dir.sh new 从树内表值机械推导)
#
# 规则(见 docs/kubespray-versioning/design.md §3.2):
#   · 选定档案后, 本文件的版本面变量**接管** cluster.conf / cluster.defaults.conf 的同名变量(档案 > 两者);
#   · 要手工钉某一项 → KUBESPRAY_PROFILE=none;
#   · 字段真值由 check-modules.sh ⑯ 对照该版本树表值逐项断言。
#   · K8S_VERSION=v1.36.5 默认取 kubelet_checksums 表首(最高线); --k8s-version 可显式覆盖。
KUBESPRAY_VERSION=v2.32.1
K8S_VERSION=v1.36.5
PAUSE_VERSION=3.10.2
COREDNS_VERSION=v1.14.2
DNS_NODE_CACHE_VERSION=1.25.0
ETCD_VERSION=v3.6.15
CALICO_VERSION=v3.32.2
METRICS_SERVER_VERSION=v0.9.0
CPA_VERSION=v1.10.3
API_LB_NGINX_IMAGE_TAG=1.30.1-alpine
LOCAL_VOLUME_PROVISIONER_VERSION=2.10.0
NFD_VERSION=0.19.0
