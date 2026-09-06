# Cache-pull tier: minimal ARM64 instance for FlakeHub cache pulls only.
# Cannot compile kernels (0.5 GiB RAM, burstable CPU). ~$6.77/mo.
instance_type       = "t4g.nano"
volume_size         = 16
volume_throughput   = 125
